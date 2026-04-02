import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSReliabilityPolicy, QoSHistoryPolicy
from sensor_msgs.msg import Image
from vision_msgs.msg import Detection2DArray
from std_msgs.msg import Float32, String
from cv_bridge import CvBridge
import cv2
import numpy as np
import time
from PIL import Image as PILImage

# COCO class names (subset for readability)
COCO_NAMES = {
    0: 'person', 1: 'bicycle', 2: 'car', 3: 'motorcycle', 4: 'airplane',
    5: 'bus', 6: 'train', 7: 'truck', 8: 'boat', 9: 'traffic light',
    10: 'fire hydrant', 14: 'bird', 15: 'cat', 16: 'dog', 17: 'horse',
    56: 'chair', 57: 'couch', 58: 'potted plant', 59: 'bed', 60: 'dining table',
    62: 'tv', 63: 'laptop', 67: 'cell phone', 74: 'clock', 76: 'scissors',
}


class LlavaNode(Node):
    """
    ROS 2 node for LLaVA-1.5-7b visual reasoning.

    Subscribes to:
      - /camera/image_raw         : live camera frames (sensor_msgs/Image)
      - /detections               : YOLO detection results (trigger)
      - /llava/trigger            : arbitrary text prompt (from Voxtral or manual)

    Publishes:
      - /llava/response           : std_msgs/String  — LLaVA text output
      - /llava/metrics_latency_ms : std_msgs/Float32 — end-to-end latency
      - /llava/metrics_inference_ms: std_msgs/Float32 — model inference time
    """

    def __init__(self):
        super().__init__('llava_node')

        # ── Parameters ──────────────────────────────────────────────
        self.declare_parameter('model_id', 'llava-hf/llava-1.5-7b-hf')
        self.declare_parameter('image_topic', '/camera/image_raw')
        self.declare_parameter('detection_topic', '/detections')
        self.declare_parameter('trigger_topic', '/llava/trigger')
        self.declare_parameter('response_topic', '/llava/response')
        self.declare_parameter('latency_topic', '/llava/metrics_latency_ms')
        self.declare_parameter('inference_topic', '/llava/metrics_inference_ms')
        self.declare_parameter('trigger_on_yolo', True)
        self.declare_parameter('yolo_trigger_interval_s', 8.0)
        self.declare_parameter('max_new_tokens', 150)
        self.declare_parameter('load_in_4bit', True)
        self.declare_parameter('hf_cache_dir', '/opt/huggingface_cache')

        model_id = self.get_parameter('model_id').value
        hf_cache  = self.get_parameter('hf_cache_dir').value

        # ── Load model ───────────────────────────────────────────────
        self.get_logger().info(f'[LLaVA] Loading model {model_id} ...')
        self._load_model(model_id, hf_cache)
        self.get_logger().info('[LLaVA] Model ready.')

        # ── cv_bridge ────────────────────────────────────────────────
        self._bridge = CvBridge()

        # ── State ────────────────────────────────────────────────────
        self.current_frame: PILImage.Image | None = None
        self.is_processing = False
        self.last_yolo_trigger = 0.0
        self._yolo_interval = self.get_parameter('yolo_trigger_interval_s').value

        # ── QoS ──────────────────────────────────────────────────────
        sensor_qos = QoSProfile(depth=1)
        sensor_qos.reliability = QoSReliabilityPolicy.BEST_EFFORT
        sensor_qos.history    = QoSHistoryPolicy.KEEP_LAST

        # ── Subscriptions ─────────────────────────────────────────────
        img_topic = self.get_parameter('image_topic').value
        self.create_subscription(Image, img_topic,
                                 self._image_cb, sensor_qos)

        trigger_topic = self.get_parameter('trigger_topic').value
        self.create_subscription(String, trigger_topic,
                                 self._trigger_cb, 10)

        if self.get_parameter('trigger_on_yolo').value:
            det_topic = self.get_parameter('detection_topic').value
            self.create_subscription(Detection2DArray, det_topic,
                                     self._detection_cb, 10)

        # ── Publishers ────────────────────────────────────────────────
        self._pub_response = self.create_publisher(
            String, self.get_parameter('response_topic').value, 10)
        self._pub_latency  = self.create_publisher(
            Float32, self.get_parameter('latency_topic').value, 10)
        self._pub_inference = self.create_publisher(
            Float32, self.get_parameter('inference_topic').value, 10)

        self.get_logger().info('[LLaVA] Node running.')

    # ── Model loading ─────────────────────────────────────────────────

    def _load_model(self, model_id: str, cache_dir: str):
        import torch
        from transformers import LlavaForConditionalGeneration, AutoProcessor

        self._dtype = torch.float16
        kwargs = dict(
            cache_dir=cache_dir,
            torch_dtype=self._dtype,
            device_map='auto',
            low_cpu_mem_usage=True,
        )

        if self.get_parameter('load_in_4bit').value:
            try:
                from transformers import BitsAndBytesConfig
                kwargs['quantization_config'] = BitsAndBytesConfig(
                    load_in_4bit=True,
                    bnb_4bit_compute_dtype=torch.float16,
                    bnb_4bit_use_double_quant=True,
                )
                self.get_logger().info('[LLaVA] Using 4-bit quantization (bitsandbytes).')
            except Exception as e:
                self.get_logger().warn(f'[LLaVA] bitsandbytes unavailable ({e}), using FP16.')

        self._processor = AutoProcessor.from_pretrained(model_id, cache_dir=cache_dir)
        self._model     = LlavaForConditionalGeneration.from_pretrained(model_id, **kwargs)
        self._model.eval()

    # ── Callbacks ─────────────────────────────────────────────────────

    def _image_cb(self, msg: Image):
        """Keep the latest camera frame in memory."""
        try:
            bgr = self._bridge.imgmsg_to_cv2(msg, desired_encoding='bgr8')
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            self.current_frame = PILImage.fromarray(rgb)
        except Exception as e:
            self.get_logger().debug(f'[LLaVA] Image decode error: {e}')

    def _detection_cb(self, msg: Detection2DArray):
        """YOLO trigger — fires LLaVA when objects are detected."""
        if not msg.detections or self.is_processing:
            return
        now = time.time()
        if now - self.last_yolo_trigger < self._yolo_interval:
            return
        self.last_yolo_trigger = now

        # Build prompt from detections
        names = []
        for d in msg.detections:
            if d.results:
                cls = int(d.results[0].hypothesis.class_id)
                names.append(COCO_NAMES.get(cls, f'object_{cls}'))

        if not names:
            return

        unique = list(dict.fromkeys(names))  # preserve order, deduplicate
        det_str = ', '.join(unique)
        prompt = (
            f'A factory robot camera sees: {det_str}. '
            f'Briefly describe the scene in 2 sentences and any safety concerns.'
        )
        self._run_inference(prompt)

    def _trigger_cb(self, msg: String):
        """Manual / Voxtral trigger — runs LLaVA with the given question."""
        if not msg.data.strip():
            return
        self._run_inference(msg.data.strip())

    # ── Inference ─────────────────────────────────────────────────────

    def _run_inference(self, question: str):
        if self.current_frame is None:
            self.get_logger().warn('[LLaVA] No frame available yet — skipping.')
            return
        if self.is_processing:
            self.get_logger().debug('[LLaVA] Already processing — skipping trigger.')
            return

        self.is_processing = True
        t_start = time.time()

        try:
            import torch

            # LLaVA chat template
            prompt_text = f'USER: <image>\n{question}\nASSISTANT:'

            inputs = self._processor(
                text=prompt_text,
                images=self.current_frame,
                return_tensors='pt'
            ).to(self._model.device)

            t_inf_start = time.time()
            with torch.inference_mode():
                output_ids = self._model.generate(
                    **inputs,
                    max_new_tokens=self.get_parameter('max_new_tokens').value,
                    do_sample=False,
                )
            t_inf_end = time.time()

            # Decode only the generated tokens
            gen_ids = output_ids[0][inputs['input_ids'].shape[1]:]
            response = self._processor.decode(gen_ids, skip_special_tokens=True).strip()

            t_end = time.time()
            latency_ms  = (t_end - t_start) * 1000.0
            inference_ms = (t_inf_end - t_inf_start) * 1000.0

            # Publish
            resp_msg = String(); resp_msg.data = response
            self._pub_response.publish(resp_msg)

            lat = Float32(); lat.data = float(latency_ms)
            self._pub_latency.publish(lat)

            inf = Float32(); inf.data = float(inference_ms)
            self._pub_inference.publish(inf)

            self.get_logger().info(
                f'[LLaVA] {inference_ms:.0f}ms | {response[:100]}...'
            )

        except Exception as e:
            self.get_logger().error(f'[LLaVA] Inference error: {e}')
        finally:
            self.is_processing = False


def main(args=None):
    rclpy.init(args=args)
    node = LlavaNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
