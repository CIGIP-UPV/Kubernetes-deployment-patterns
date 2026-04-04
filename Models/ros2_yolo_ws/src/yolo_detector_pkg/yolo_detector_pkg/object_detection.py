import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSReliabilityPolicy, QoSHistoryPolicy
from rclpy.time import Time
from sensor_msgs.msg import Image, CompressedImage
from vision_msgs.msg import Detection2DArray, Detection2D, ObjectHypothesisWithPose
from std_msgs.msg import Float32
import numpy as np
from cv_bridge import CvBridge
from ultralytics import YOLO
import cv2
import time

class YoloDetector(Node):
    """
    Suscribe a /camera/image_raw, ejecuta YOLO y publica:
      - /detections (vision_msgs/Detection2DArray)
      - /detections/image (sensor_msgs/Image) [opcional, imagen anotada]

    Parámetro filter_classes:
      - "" (vacío)  → publica TODAS las clases (80 COCO)
      - "0"         → solo personas
      - "0,16,17"   → personas + perros + gatos
      Los IDs corresponden al dataset COCO de YOLOv8.
    """
    # Colores distintos para las 10 primeras clases (BGR)
    PALETTE = [
        (0, 255, 0),    # green  - person
        (255, 128, 0),  # blue-ish - bicycle
        (0, 128, 255),  # orange - car
        (255, 0, 255),  # magenta - motorcycle
        (255, 255, 0),  # cyan - airplane
        (0, 255, 255),  # yellow - bus
        (128, 0, 255),  # purple - train
        (255, 0, 128),  # pink - truck
        (0, 200, 128),  # teal - boat
        (128, 255, 0),  # lime - traffic light
    ]

    def __init__(self):
        super().__init__('yolo_detector')

        self.declare_parameters('', [
            ('model_path', 'yolov8n.pt'),
            ('conf', 0.25),
            ('image_topic', '/camera/image_raw'),
            ('publish_debug_image', True),
            ('detections_topic', '/detections'),
            ('debug_image_topic', '/detections/image'),
            ('publish_metrics', True),
            ('latency_topic', '/benchmark/latency_ms'),
            ('inference_topic', '/benchmark/inference_ms'),
            ('filter_classes', ''),
        ])

        # ── GPU diagnostic ───────────────────────────────────────────
        import torch
        cuda_ok = torch.cuda.is_available()
        self.get_logger().info(f'[YOLO] torch.cuda.is_available() = {cuda_ok}')
        if cuda_ok:
            self.get_logger().info(
                f'[YOLO] GPU: {torch.cuda.get_device_name(0)} | '
                f'CUDA {torch.version.cuda} | '
                f'VRAM {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')
            # Enable cuDNN benchmark mode for best conv algorithm selection
            torch.backends.cudnn.benchmark = True
            self.get_logger().info('[YOLO] cuDNN benchmark mode enabled')
        else:
            self.get_logger().warn('[YOLO] CUDA not available — model will run on CPU (slow!)')

        self.model = YOLO(self.get_parameter('model_path').value)
        self.model.fuse()  # slight optimisation

        # Parse filter_classes: "" → None (all), "0" → {0}, "0,16" → {0,16}
        raw = str(self.get_parameter('filter_classes').value).strip()
        if raw:
            self.filter_classes = set(int(c.strip()) for c in raw.split(',') if c.strip())
        else:
            self.filter_classes = None

        # COCO class names from the model
        self.class_names = self.model.names  # dict {0: 'person', 1: 'bicycle', ...}

        if self.filter_classes:
            names = [self.class_names.get(c, str(c)) for c in sorted(self.filter_classes)]
            self.get_logger().info(f'Filtrando clases: {names} (IDs: {sorted(self.filter_classes)})')
        else:
            self.get_logger().info('Detectando TODAS las clases COCO (80 clases)')

        self.bridge = CvBridge()

        sensor_qos = QoSProfile(depth=1)
        sensor_qos.reliability = QoSReliabilityPolicy.BEST_EFFORT
        sensor_qos.history = QoSHistoryPolicy.KEEP_LAST

        self.sub = self.create_subscription(
            Image, self.get_parameter('image_topic').value, self.image_cb, sensor_qos
        )
        self.pub_det = self.create_publisher(
            Detection2DArray,
            self.get_parameter('detections_topic').value,
            10,
        )

        self.publish_debug = bool(self.get_parameter('publish_debug_image').value)
        if self.publish_debug:
            # JPEG compressed image for web dashboard (much smaller over WebSocket)
            self.pub_img_compressed = self.create_publisher(
                CompressedImage,
                self.get_parameter('debug_image_topic').value + '/compressed',
                10,
            )

        self.publish_metrics = bool(self.get_parameter('publish_metrics').value)
        if self.publish_metrics:
            self.pub_latency = self.create_publisher(
                Float32,
                self.get_parameter('latency_topic').value,
                50,
            )
            self.pub_inference = self.create_publisher(
                Float32,
                self.get_parameter('inference_topic').value,
                50,
            )
        self.frame_counter = 0
        self.stats_started_at = time.monotonic()

        self.get_logger().info('YOLO detector inicializado')

    def image_cb(self, msg: Image):
        # Imagen BGR de OpenCV
        frame = self.bridge.imgmsg_to_cv2(msg, desired_encoding='bgr8')

        # Inferencia
        infer_start = time.perf_counter()
        conf = float(self.get_parameter('conf').value)
        result = self.model.predict(frame, conf=conf, verbose=False)[0]
        infer_ms = (time.perf_counter() - infer_start) * 1000.0

        out = Detection2DArray()
        out.header = msg.header

        # Dibujado opcional sobre copia del frame
        if self.publish_debug:
            dbg = frame.copy()

        for b in result.boxes:
            x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
            cls = int(b.cls[0]) if b.cls is not None else -1
            sc  = float(b.conf[0]) if b.conf is not None else 0.0

            # Filtrar por clases si está configurado
            if self.filter_classes is not None and cls not in self.filter_classes:
                continue

            det = Detection2D()
            # bbox como centro + tamaño (formato vision_msgs)
            det.bbox.center.position.x = (x1 + x2) / 2.0
            det.bbox.center.position.y = (y1 + y2) / 2.0
            det.bbox.center.theta = 0.0
            det.bbox.size_x = (x2 - x1)
            det.bbox.size_y = (y2 - y1)

            hyp = ObjectHypothesisWithPose()
            hyp.hypothesis.class_id = str(cls)  # id de clase COCO
            hyp.hypothesis.score = sc
            det.results.append(hyp)
            out.detections.append(det)

            if self.publish_debug:
                color = self.PALETTE[cls % len(self.PALETTE)]
                class_name = self.class_names.get(cls, str(cls))
                cv2.rectangle(dbg, (int(x1), int(y1)), (int(x2), int(y2)), color, 2)
                label = f'{class_name} {sc:.0%}'
                # Fondo para el texto (mejor legibilidad)
                (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
                cv2.rectangle(dbg, (int(x1), int(y1)-th-6), (int(x1)+tw, int(y1)), color, -1)
                cv2.putText(dbg, label, (int(x1), int(max(0, y1-4))),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 2, cv2.LINE_AA)

        # Publicaciones
        self.pub_det.publish(out)
        if self.publish_debug:
            # Publish JPEG compressed image for web dashboard
            # Quality 90 ≈ 100-150 KB/frame (good visual quality, viable over WebSocket)
            comp_msg = CompressedImage()
            comp_msg.header = msg.header
            comp_msg.format = 'jpeg'
            comp_msg.data = np.array(cv2.imencode('.jpg', dbg, [cv2.IMWRITE_JPEG_QUALITY, 90])[1]).tobytes()
            self.pub_img_compressed.publish(comp_msg)
        if self.publish_metrics:
            stamp = Time.from_msg(msg.header.stamp, clock_type=self.get_clock().clock_type)
            now = self.get_clock().now()
            latency_ms = (now.nanoseconds - stamp.nanoseconds) / 1e6
            if latency_ms < 0:
                self.get_logger().warn(
                    f'Latencia negativa ({latency_ms:.3f} ms); publicando 0.0 ms para no perder la muestra'
                )
                latency_ms = 0.0
            self.pub_latency.publish(Float32(data=float(latency_ms)))
            self.pub_inference.publish(Float32(data=float(infer_ms)))

        self.frame_counter += 1
        if self.frame_counter % 50 == 0:
            elapsed = max(time.monotonic() - self.stats_started_at, 1e-6)
            fps = self.frame_counter / elapsed
            self.get_logger().info(f'Frames={self.frame_counter} FPS={fps:.2f}')

def main():
    rclpy.init()
    node = YoloDetector()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()

if __name__ == '__main__':
    main()
