import platform as _platform
import sys as _sys
import types as _types

# ── Jetson PyTorch distributed stub ──────────────────────────────────────
# The NVIDIA Jetson PyTorch wheel is built without distributed support, so
# torch._C._distributed_c10d does not exist.  transformers calls
# torch.distributed internally during generate(), which triggers the import
# and crashes.  We inject a minimal stub *before* anything imports torch so
# the import chain never breaks.
if _platform.machine() == 'aarch64':
    # ── Permissive metaclass (defined first, used everywhere) ────────
    # Every dummy class created with this metaclass will return another
    # permissive dummy for ANY attribute access (e.g. ProcessGroup.BackendType).
    class _PermissiveMeta(type):
        def __getattr__(cls, name):
            # __members__ is used by enum introspection (e.g.
            # ReduceOp.RedOpType.__members__.items()) — must return a
            # real dict so .items() is iterable.
            if name == '__members__':
                return {}
            return _PermissiveMeta(name, (), {'__module__': cls.__module__})
        def __instancecheck__(cls, instance):
            return True
        def __call__(cls, *a, **kw):
            return object.__new__(cls)

    # ── 1. torch._C._distributed_c10d — permissive stub ──────────────
    # The Jetson PyTorch wheel lacks distributed support.  When
    # torch.distributed.__init__.py does:
    #   from torch._C._distributed_c10d import ProcessGroup, Store, ...
    # these classes MUST already use _PermissiveMeta so that any code
    # that caches them gets the permissive behavior (e.g. ProcessGroup.BackendType).
    class _PermissiveModule(_types.ModuleType):
        def __getattr__(self, name):
            if name.startswith('__') and name.endswith('__'):
                raise AttributeError(name)
            return _PermissiveMeta(name, (), {'__module__': self.__name__})

    _stub = _PermissiveModule('torch._C._distributed_c10d')
    _sys.modules['torch._C._distributed_c10d'] = _stub

    # ── 2. torch.distributed — ensure importable ─────────────────────
    try:
        import torch.distributed  # noqa: F401
    except ImportError:
        _dist = _types.ModuleType('torch.distributed')
        _dist.is_available = lambda: False
        _dist.is_initialized = lambda: False
        _sys.modules['torch.distributed'] = _dist

    # Safety net: torch.distributed.__init__.py may not import all names
    # from _distributed_c10d (varies by wheel build).  Fill in any gaps.
    _dist_mod = _sys.modules.get('torch.distributed')
    if _dist_mod is not None:
        for _name in ('Store', 'FileStore', 'TCPStore', 'HashStore',
                       'PrefixStore', 'ProcessGroup', 'Work', 'ReduceOp',
                       'Backend'):
            if not hasattr(_dist_mod, _name):
                setattr(_dist_mod, _name, _PermissiveMeta(
                    _name, (), {'__module__': 'torch.distributed'}))

    # ── 2b. Mock fake_pg — prevent fsdp cascade at runtime ────────────
    # When generate() triggers import of torch.distributed.fsdp, it
    # cascades into fake_pg.py which needs full distributed support.
    # Mocking fake_pg cuts this chain cleanly.
    _fake_pg = _types.ModuleType('torch.testing._internal.distributed.fake_pg')
    _fake_pg.FakeProcessGroup = type('FakeProcessGroup', (), {})
    _fake_pg.FakeStore = type('FakeStore', (), {})
    _sys.modules['torch.testing._internal.distributed.fake_pg'] = _fake_pg

    # ── 3. torch._C attribute — for "from torch._C import ..." syntax ─
    try:
        import torch._C as _torch_C
        if not hasattr(_torch_C, '_distributed_c10d'):
            _torch_C._distributed_c10d = _stub
    except Exception:
        pass

    # ── 4. Mock torch._dynamo — THE KEY FIX ──────────────────────────
    # torch._dynamo is the torch.compile() / Triton compiler frontend.
    # It is NOT supported on aarch64 (no Triton backend).
    #
    # Multiple torchvision entry points import torch._dynamo:
    #   - ops/roi_align.py → torch._dynamo.utils.is_compile_supported
    #   - tv_tensors/__init__.py → @torch.compiler.disable → import torch._dynamo
    #   - (and potentially more)
    #
    # Each one cascades into:
    #   torch._dynamo → torch.distributed.fsdp → fake_pg.py
    #   → torch._C._distributed_c10d (missing symbols)
    #   → torch.distributed.Store/Backend/ProcessGroup (missing)
    #
    # Instead of patching each entry point, we mock torch._dynamo itself.
    # This is safe because torch.compile() cannot work on Jetson anyway.
    if 'torch._dynamo' not in _sys.modules:
        _dynamo = _types.ModuleType('torch._dynamo')
        _dynamo.is_compiling = lambda: False
        _dynamo.assume_constant_result = lambda fn: fn
        # disable() is used as a decorator: @torch.compiler.disable
        def _mock_disable(fn=None, recursive=True):
            if fn is not None:
                return fn
            return lambda f: f
        _dynamo.disable = _mock_disable
        _dynamo.utils = _types.ModuleType('torch._dynamo.utils')
        _dynamo.utils.is_compile_supported = lambda device_type="": False
        _sys.modules['torch._dynamo'] = _dynamo
        _sys.modules['torch._dynamo.utils'] = _dynamo.utils

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
        self.declare_parameter('yolo_trigger_interval_s', 8.0)  # float; Helm may pass int
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
        self._yolo_interval = float(self.get_parameter('yolo_trigger_interval_s').value)
        self._pending_manual_prompt: str | None = None  # manual triggers queue

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

        # ── GPU diagnostic ───────────────────────────────────────────
        cuda_ok = torch.cuda.is_available()
        self.get_logger().info(f'[LLaVA] torch.cuda.is_available() = {cuda_ok}')
        if cuda_ok:
            self.get_logger().info(
                f'[LLaVA] GPU: {torch.cuda.get_device_name(0)} | '
                f'CUDA {torch.version.cuda} | '
                f'VRAM {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')
        else:
            self.get_logger().warn('[LLaVA] CUDA not available — model will run on CPU (slow!)')

        if cuda_ok:
            torch.backends.cudnn.benchmark = True
            self.get_logger().info('[LLaVA] cuDNN benchmark mode enabled')

        self._dtype = torch.float16

        # Jetson: bitsandbytes CUDA kernels are compiled for datacenter GPUs
        # and fail on Jetson (Error named symbol not found).  With 64 GB VRAM
        # LLaVA-1.5-7B fits comfortably in FP16 (~14 GB), so skip 4-bit.
        # Also: Jetson PyTorch wheel lacks torch._C._distributed_c10d,
        # so device_map='auto' (which uses accelerate dispatch hooks) crashes
        # at inference time.  Load to CUDA manually instead.
        import platform
        is_jetson = (platform.machine() == 'aarch64' and cuda_ok)

        # local_files_only=True — model is baked into the image at
        # /opt/huggingface_cache during build; without this flag transformers
        # tries to validate revisions against the Hub and aborts with
        # "offline mode is enabled" instead of using the local cache.
        kwargs = dict(
            cache_dir=cache_dir,
            torch_dtype=self._dtype,
            low_cpu_mem_usage=True,
            local_files_only=True,
        )
        if not is_jetson:
            kwargs['device_map'] = 'auto'

        if self.get_parameter('load_in_4bit').value and not is_jetson:
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
        elif is_jetson:
            self.get_logger().info(
                '[LLaVA] Jetson detected — skipping bitsandbytes, using FP16 '
                f'({torch.cuda.get_device_properties(0).total_memory / 1e9:.0f} GB VRAM available).')

        self._processor = AutoProcessor.from_pretrained(
            model_id, cache_dir=cache_dir, local_files_only=True)

        # LLaVA-1.5's LLaMA tokenizer ships without a pad_token. Even with
        # `padding=True`, the processor fails with "Unable to create tensor,
        # you should probably activate padding". The standard HF fix is to
        # alias pad_token to eos_token before any tokenization happens.
        tok = getattr(self._processor, 'tokenizer', None)
        if tok is not None and tok.pad_token is None:
            tok.pad_token = tok.eos_token
            self.get_logger().info(
                '[LLaVA] Set tokenizer.pad_token = eos_token (LLaMA has no pad by default).')

        # transformers >=4.47 warns (and in 4.55 errors) if LlavaProcessor
        # doesn't have patch_size / vision_feature_select_strategy set on the
        # processor itself. Pull them from the model config below if missing.

        self._model     = LlavaForConditionalGeneration.from_pretrained(model_id, **kwargs)

        # Backfill processor attrs from the model config (defensive)
        try:
            if getattr(self._processor, 'patch_size', None) is None:
                self._processor.patch_size = self._model.config.vision_config.patch_size
            if getattr(self._processor, 'vision_feature_select_strategy', None) is None:
                self._processor.vision_feature_select_strategy = \
                    getattr(self._model.config, 'vision_feature_select_strategy', 'default')
        except Exception as e:
            self.get_logger().warn(f'[LLaVA] Processor backfill skipped: {e}')
        if is_jetson:
            self._model = self._model.to('cuda')
            self.get_logger().info('[LLaVA] Model moved to CUDA (Jetson direct placement).')
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
        """Manual / Voxtral trigger — runs LLaVA with the given question.
        If currently processing, queue the prompt so it runs next."""
        if not msg.data.strip():
            return
        if self.is_processing:
            self._pending_manual_prompt = msg.data.strip()
            self.get_logger().info('[LLaVA] Manual prompt queued (inference in progress).')
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

            # ── Defensive guard: re-apply processor state right before the call.
            # transformers 4.48 LlavaProcessor occasionally needs patch_size /
            # vision_feature_select_strategy set ON THE PROCESSOR INSTANCE for
            # the <image> token to be expanded correctly during __call__. If
            # they're missing, the resulting BatchEncoding has mismatched
            # shapes and the cryptic "Unable to create tensor, you should
            # probably activate padding" error surfaces from the tokenizer.
            tok = getattr(self._processor, 'tokenizer', None)
            if tok is not None and tok.pad_token is None:
                tok.pad_token = tok.eos_token
            if getattr(self._processor, 'patch_size', None) is None:
                try:
                    self._processor.patch_size = self._model.config.vision_config.patch_size
                except Exception:
                    self._processor.patch_size = 14  # LLaVA-1.5 default
            if getattr(self._processor, 'vision_feature_select_strategy', None) is None:
                self._processor.vision_feature_select_strategy = getattr(
                    self._model.config, 'vision_feature_select_strategy', 'default')

            # One-time diagnostic log of the actual runtime state.
            if not getattr(self, '_inference_state_logged', False):
                self.get_logger().info(
                    f'[LLaVA] Processor state @ first inference: '
                    f'pad_token={tok.pad_token!r}, '
                    f'patch_size={self._processor.patch_size}, '
                    f'vfss={self._processor.vision_feature_select_strategy}, '
                    f'image_token_index={getattr(self._model.config, "image_token_index", None)}'
                )
                self._inference_state_logged = True

            batch = self._processor(
                text=prompt_text,
                images=self.current_frame,
                return_tensors='pt',
                padding=True
            )
            inputs = {k: v.to(self._model.device) for k, v in batch.items()}

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
            import traceback
            self.get_logger().error(
                f'[LLaVA] Inference error: {type(e).__name__}: {e}\n'
                f'{traceback.format_exc()}'
            )
        finally:
            self.is_processing = False
            # Process queued manual prompt (priority over YOLO auto-triggers)
            if self._pending_manual_prompt:
                prompt = self._pending_manual_prompt
                self._pending_manual_prompt = None
                self.get_logger().info('[LLaVA] Processing queued manual prompt...')
                self._run_inference(prompt)


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
