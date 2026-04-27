"""
Voxtral interaction node — ROS 2 / Kubernetes Deployment Patterns
=================================================================

Mode A — TEXT SIMULATION (VOXTRAL_AUDIO_MODE=false):
  The operator sends text commands via the /voice/command topic.
  The node routes questions to LLaVA and publishes responses to /voice/response.
  No audio hardware required. Useful for initial integration testing.

Mode B — AUDIO (VOXTRAL_AUDIO_MODE=true):
  Captures audio from a USB/ALSA microphone (e.g., camera built-in mic).
  Loads the Voxtral speech/audio-language model for speech recognition.
  Publishes transcripts and forwards scene questions to LLaVA.

Topics
------
  Subscribes:
    /voice/command   (std_msgs/String)  — operator text input (text sim mode)
    /llava/response  (std_msgs/String)  — LLaVA answers to speak back
  Publishes:
    /voice/transcript (std_msgs/String) — what the operator said (raw text)
    /voice/response   (std_msgs/String) — Voxtral/system reply
    /llava/trigger    (std_msgs/String) — forwarded question to LLaVA
    /voice/metrics_latency_ms (std_msgs/Float32) — round-trip latency
"""

import platform as _platform
import sys as _sys
import types as _types

# ── Jetson PyTorch distributed stub ──────────────────────────────────────
# The NVIDIA Jetson PyTorch wheel is built without distributed support, so
# torch._C._distributed_c10d does not exist. transformers calls
# torch.distributed internally during generate(), which triggers the import
# and crashes. We inject a minimal stub *before* anything imports torch so
# the import chain never breaks. Mirrors the stubs used in llava_node.py.
if _platform.machine() == 'aarch64':
    class _PermissiveMeta(type):
        def __getattr__(cls, name):
            if name == '__members__':
                return {}
            return _PermissiveMeta(name, (), {'__module__': cls.__module__})
        def __instancecheck__(cls, instance):
            return True
        def __call__(cls, *a, **kw):
            return object.__new__(cls)

    class _PermissiveModule(_types.ModuleType):
        def __getattr__(self, name):
            if name.startswith('__') and name.endswith('__'):
                raise AttributeError(name)
            return _PermissiveMeta(name, (), {'__module__': self.__name__})

    _stub = _PermissiveModule('torch._C._distributed_c10d')
    _sys.modules['torch._C._distributed_c10d'] = _stub

    try:
        import torch.distributed  # noqa: F401
    except ImportError:
        _dist = _types.ModuleType('torch.distributed')
        _dist.is_available = lambda: False
        _dist.is_initialized = lambda: False
        _sys.modules['torch.distributed'] = _dist

    _dist_mod = _sys.modules.get('torch.distributed')
    if _dist_mod is not None:
        for _name in ('Store', 'FileStore', 'TCPStore', 'HashStore',
                      'PrefixStore', 'ProcessGroup', 'Work', 'ReduceOp',
                      'Backend'):
            if not hasattr(_dist_mod, _name):
                setattr(_dist_mod, _name, _PermissiveMeta(
                    _name, (), {'__module__': 'torch.distributed'}))

    _fake_pg = _types.ModuleType('torch.testing._internal.distributed.fake_pg')
    _fake_pg.FakeProcessGroup = type('FakeProcessGroup', (), {})
    _fake_pg.FakeStore = type('FakeStore', (), {})
    _sys.modules['torch.testing._internal.distributed.fake_pg'] = _fake_pg

    try:
        import torch._C as _torch_C
        if not hasattr(_torch_C, '_distributed_c10d'):
            _torch_C._distributed_c10d = _stub
    except Exception:
        pass

    if 'torch._dynamo' not in _sys.modules:
        # Pass-through callable: works both as `fn = dynamo.decorator(fn)`
        # (returns its argument unchanged) and as a plain no-op function.
        def _dynamo_passthrough(*args, **kwargs):
            if len(args) == 1 and callable(args[0]) and not kwargs:
                return args[0]
            return _dynamo_passthrough

        class _DynamoModule(_types.ModuleType):
            """Permissive stub for torch._dynamo. Any attribute access
            returns a pass-through decorator/function, which covers
            allow_in_graph, mark_dynamic, mark_static, skip_frame, etc.
            as transformers adds new decorators across releases."""
            def __getattr__(self, name):
                if name.startswith('__') and name.endswith('__'):
                    raise AttributeError(name)
                return _dynamo_passthrough

        _dynamo = _DynamoModule('torch._dynamo')
        _dynamo.is_compiling = lambda: False
        _dynamo.assume_constant_result = lambda fn: fn
        def _mock_disable(fn=None, recursive=True):
            if fn is not None:
                return fn
            return lambda f: f
        _dynamo.disable = _mock_disable

        _dynamo_utils = _DynamoModule('torch._dynamo.utils')
        _dynamo_utils.is_compile_supported = lambda device_type="": False

        _sys.modules['torch._dynamo'] = _dynamo
        _sys.modules['torch._dynamo.utils'] = _dynamo_utils

import rclpy
from rclpy.node import Node
from std_msgs.msg import String, Float32, Int16MultiArray
import time
import threading
import os
import tempfile
import traceback


# Keywords that indicate the operator wants visual scene analysis
SCENE_KEYWORDS = {
    # English
    'what', 'describe', 'see', 'show', 'tell', 'explain', 'look',
    'analyze', 'analyse', 'identify', 'detect', 'scene', 'camera',
    'happening', 'going on', 'observe',
    # Spanish
    'qué', 'que', 'describe', 'ves', 'hay', 'dime', 'cuéntame', 'cuentame',
    'muestra', 'explica', 'analiza', 'mira', 'ocurre', 'pasa', 'escena',
    'observa', 'detecta', 'identifica',
}


class VoxtralNode(Node):
    """
    ROS 2 node for human–robot voice interaction.

    In text simulation mode (default) no model is loaded;
    the node acts as an intelligent router between the operator,
    LLaVA, and any future TTS backend.
    """

    def __init__(self):
        super().__init__('voxtral_node')

        # ── Parameters ────────────────────────────────────────────────
        self.declare_parameter('audio_mode',          False)
        self.declare_parameter('model_id',            'mistralai/Voxtral-Mini-3B-2507')
        self.declare_parameter('command_topic',       '/voice/command')
        self.declare_parameter('transcript_topic',    '/voice/transcript')
        self.declare_parameter('response_topic',      '/voice/response')
        self.declare_parameter('llava_trigger_topic', '/llava/trigger')
        self.declare_parameter('llava_response_topic','/llava/response')
        self.declare_parameter('latency_topic',       '/voice/metrics_latency_ms')
        self.declare_parameter('audio_chunk_topic',   '/voice/audio_chunk')
        self.declare_parameter('audio_sample_rate',   16000)
        self.declare_parameter('hf_cache_dir',        '/opt/huggingface_cache')

        self._audio_mode = self.get_parameter('audio_mode').value
        self._pending_trigger_time: float | None = None
        self._lock = threading.Lock()
        # Model state — populated in _init_audio_mode() if audio_mode=True.
        # Kept as None here so the browser-audio callback can skip gracefully
        # when inference isn't available (model still loading or text-sim mode).
        self._processor = None
        self._model = None
        self._model_ready = False
        self._audio_sample_rate = int(self.get_parameter('audio_sample_rate').value)

        # ── Publishers ────────────────────────────────────────────────
        self._pub_transcript = self.create_publisher(
            String, self.get_parameter('transcript_topic').value, 10)
        self._pub_response = self.create_publisher(
            String, self.get_parameter('response_topic').value, 10)
        self._pub_llava = self.create_publisher(
            String, self.get_parameter('llava_trigger_topic').value, 10)
        self._pub_latency = self.create_publisher(
            Float32, self.get_parameter('latency_topic').value, 10)

        # ── Subscriptions ─────────────────────────────────────────────
        self.create_subscription(
            String,
            self.get_parameter('command_topic').value,
            self._command_cb, 10)

        self.create_subscription(
            String,
            self.get_parameter('llava_response_topic').value,
            self._llava_response_cb, 10)

        # Browser-captured audio (from dashboard via rosbridge). Always
        # subscribed: if the model isn't loaded yet, the callback drops
        # the chunk with a debug log instead of crashing.
        self.create_subscription(
            Int16MultiArray,
            self.get_parameter('audio_chunk_topic').value,
            self._audio_chunk_cb, 10)

        if self._audio_mode:
            self.get_logger().info('[Voxtral] Starting in AUDIO mode.')
            self._init_audio_mode()
        else:
            self.get_logger().info(
                '[Voxtral] Starting in TEXT SIMULATION mode. '
                'Send text to /voice/command to interact.'
            )

        self.get_logger().info('[Voxtral] Node ready.')

    # ── Audio mode init (Phase 2) ──────────────────────────────────────

    def _init_audio_mode(self):
        """Load Voxtral model and start microphone capture."""
        model_id  = self.get_parameter('model_id').value
        # Stash on self so the audio callbacks can pass model_id to
        # VoxtralProcessor.apply_transcrition_request(...).
        self._model_id = model_id
        cache_dir = self.get_parameter('hf_cache_dir').value

        self.get_logger().info(f'[Voxtral] Loading model {model_id} ...')
        try:
            import platform
            import torch
            # Import via submodule paths to bypass transformers' _LazyModule.
            # The torch.distributed stubs above (PermissiveMeta) interfere with
            # transformers 4.55's top-level lazy attribute resolution, so
            # `from transformers import AutoProcessor` fails even though the
            # class exists. Submodule imports work because they skip the lazy
            # dispatch entirely.
            #
            # We also bypass AutoProcessor itself: Voxtral's processor uses
            # mistral_common tokenizer + Whisper feature extractor, which isn't
            # reliably resolved by AutoProcessor.from_pretrained (it returns
            # "Unrecognized processing class"). VoxtralProcessor loads directly.
            #
            # Voxtral is a multimodal LLM with audio input
            # (VoxtralForConditionalGeneration), not a Seq2Seq speech model.
            from transformers.models.voxtral.processing_voxtral import VoxtralProcessor
            from transformers.models.voxtral.modeling_voxtral import VoxtralForConditionalGeneration

            # ── GPU diagnostic ───────────────────────────────────────
            cuda_ok = torch.cuda.is_available()
            is_jetson = (platform.machine() == 'aarch64' and cuda_ok)
            self.get_logger().info(
                f'[Voxtral] torch.cuda.is_available() = {cuda_ok} | jetson={is_jetson}')
            if cuda_ok:
                self.get_logger().info(
                    f'[Voxtral] GPU: {torch.cuda.get_device_name(0)} | '
                    f'CUDA {torch.version.cuda} | '
                    f'VRAM {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')
                # cuDNN benchmark mode — L4T-native cuDNN has pre-compiled
                # engines for Orin SM 8.7, benchmark=True picks the fastest.
                torch.backends.cudnn.benchmark = True
            else:
                self.get_logger().warn('[Voxtral] CUDA not available — model will run on CPU (slow!)')

            # ── Model loading ────────────────────────────────────────
            # On Jetson:
            #   - no bitsandbytes (kernels are for datacenter GPUs, fail on Tegra)
            #   - no device_map='auto' (accelerate uses torch.distributed internally,
            #     which is not available in the Jetson PyTorch wheel)
            #   - use FP16 directly; 64 GB unified memory is plenty for a <8B model.
            # On non-Jetson (amd64 dev):
            #   - let accelerate do its thing with device_map='auto' + FP16.
            # ── Resolve local snapshot path ──────────────────────────
            # Voxtral uses Mistral's `tekken.json` instead of the standard HF
            # tokenizer files (`tokenizer.json`, `tokenizer_config.json`, ...).
            # When you pass a model_id with `local_files_only=True`, the HF
            # cache resolver insists on the standard tokenizer files and
            # aborts with "No local files found" — even when the snapshot is
            # complete and `mistral-common` could read tekken.json fine.
            # Workaround: resolve the model_id to its on-disk snapshot path
            # via `huggingface_hub.snapshot_download(local_files_only=True)`,
            # which just returns the cached directory without touching the
            # network, then pass that absolute path to `from_pretrained`.
            # transformers then enters its "directory load" code path which
            # is more lenient and lets `mistral-common` handle tekken.json.
            from huggingface_hub import snapshot_download as _hf_snapshot
            local_path = _hf_snapshot(
                model_id, cache_dir=cache_dir, local_files_only=True)
            self.get_logger().info(
                f'[Voxtral] Resolved local snapshot: {local_path}')

            self._processor = VoxtralProcessor.from_pretrained(
                local_path, local_files_only=True)

            if is_jetson:
                # attn_implementation="eager" — the Jetson PyTorch wheel
                # (2.5.0a0 nv24.08) predates the `enable_gqa` kwarg added in
                # torch 2.6. transformers 4.55's SDPA path passes it, causing
                # TypeError at inference. "eager" uses the naive attention
                # implementation (no SDPA/FA2), slightly slower but compatible.
                self._model = VoxtralForConditionalGeneration.from_pretrained(
                    local_path,
                    torch_dtype=torch.float16,
                    low_cpu_mem_usage=True,
                    attn_implementation="eager",
                    local_files_only=True,
                )
                self._model = self._model.to('cuda')
                self.get_logger().info(
                    '[Voxtral] Model moved to CUDA (Jetson direct placement, FP16, eager attn).')
            else:
                kwargs = dict(
                    torch_dtype=torch.float16 if cuda_ok else torch.float32,
                    low_cpu_mem_usage=True,
                    local_files_only=True,
                )
                if cuda_ok:
                    kwargs['device_map'] = 'auto'
                self._model = VoxtralForConditionalGeneration.from_pretrained(local_path, **kwargs)

            self._model.eval()
            self._model_ready = True
            self.get_logger().info('[Voxtral] Model loaded. Ready for browser audio and local mic.')
            # Local mic capture — optional. Only starts if /dev/snd is mounted
            # in the container. Errors are non-fatal; browser audio via
            # /voice/audio_chunk still works without a local mic.
            self._start_mic_thread()
        except Exception as e:
            self.get_logger().error(f'[Voxtral] Failed to load model: {e}')
            self.get_logger().warn('[Voxtral] Falling back to TEXT SIMULATION mode.')
            self._audio_mode = False
            self._model_ready = False

    def _start_mic_thread(self):
        """Background thread for real-time microphone capture."""
        t = threading.Thread(target=self._mic_loop, daemon=True)
        t.start()

    def _mic_loop(self):
        """
        Capture audio from ALSA device and transcribe with Voxtral.
        Requires: pyaudio or sounddevice + the ALSA device mounted in the container.
        Phase 2 — implemented when microphone is confirmed working.

        If /dev/snd is not mounted (typical in K8s pods without --device or hostPath
        of /dev/snd), `sounddevice.query_devices()` returns -1 and the loop exits
        cleanly with an INFO message. Browser audio via /voice/audio_chunk keeps
        working — local mic is optional.
        """
        try:
            import sounddevice as sd
            import numpy as np
            import torch

            # Probe for any audio device before starting the capture loop.
            # In a containerized environment without /dev/snd mounted, this
            # returns no devices and we exit gracefully instead of spamming
            # the log with PortAudioError on every iteration.
            try:
                devices = sd.query_devices()
                has_input = any(d.get('max_input_channels', 0) > 0 for d in devices)
            except Exception:
                has_input = False

            if not has_input:
                self.get_logger().info(
                    '[Voxtral] No audio input device available (likely /dev/snd not mounted). '
                    'Local mic disabled — browser audio via /voice/audio_chunk still works.')
                return

            SAMPLE_RATE = 16000
            CHUNK_S     = 3      # seconds per chunk
            CHUNK_SAMPS = SAMPLE_RATE * CHUNK_S

            self.get_logger().info(f'[Voxtral] Mic loop started. SR={SAMPLE_RATE}, chunk={CHUNK_S}s')

            while rclpy.ok():
                audio = sd.rec(CHUNK_SAMPS, samplerate=SAMPLE_RATE,
                               channels=1, dtype='float32')
                sd.wait()
                audio_np = audio.squeeze()

                # Voxtral transcription API (mistral-common processor).
                # See _audio_chunk_cb for rationale — apply_transcrition_request
                # is the entry point that ships with transformers 4.55; some
                # newer versions also expose apply_transcription_request.
                _apply = (getattr(self._processor, 'apply_transcription_request', None)
                          or getattr(self._processor, 'apply_transcrition_request'))
                import soundfile as sf
                with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                    tmp_wav = tmp.name
                try:
                    sf.write(tmp_wav, audio_np, SAMPLE_RATE,
                             format='WAV', subtype='PCM_16')
                    inputs = _apply(
                        language='en',
                        audio=tmp_wav,
                        model_id=self._model_id,
                    )
                finally:
                    try:
                        os.unlink(tmp_wav)
                    except OSError:
                        pass
                if hasattr(inputs, 'to'):
                    inputs = inputs.to(self._model.device)
                else:
                    inputs = {k: (v.to(self._model.device) if hasattr(v, 'to') else v)
                              for k, v in inputs.items()}
                prompt_len = inputs['input_ids'].shape[1] if isinstance(inputs, dict) \
                             else inputs.input_ids.shape[1]

                with torch.inference_mode():
                    ids = self._model.generate(
                        **(inputs if isinstance(inputs, dict) else dict(inputs)),
                        max_new_tokens=128,
                    )

                text = self._processor.batch_decode(
                    ids[:, prompt_len:], skip_special_tokens=True)[0].strip()

                if text:
                    self.get_logger().info(f'[Voxtral] Transcript: {text}')
                    # Route as if received via /voice/command
                    msg = String(); msg.data = text
                    self._command_cb(msg)

        except ImportError:
            self.get_logger().error(
                '[Voxtral] sounddevice not installed. Install it to enable audio mode.')
        except Exception as e:
            self.get_logger().error(f'[Voxtral] Mic loop error: {e}')
            self.get_logger().error(
                '[Voxtral] Traceback:\n' + traceback.format_exc())

    # ── Browser audio callback (captured from dashboard via rosbridge) ─
    def _audio_chunk_cb(self, msg: Int16MultiArray):
        """
        Transcribe an audio chunk published from the browser dashboard.

        Expected payload: raw 16-bit PCM, little-endian-encoded as Int16[]
        at 16 kHz, mono. The browser-side code (dashboard.html) downsamples
        and packs the buffer before publishing.
        """
        if not self._model_ready or self._processor is None or self._model is None:
            self.get_logger().warn(
                '[Voxtral] Received browser audio but model is not loaded yet — dropping chunk.')
            return

        try:
            import numpy as np
            import torch

            # Int16[] → numpy Int16 → float32 in [-1, 1]
            samples = np.asarray(msg.data, dtype=np.int16)
            if samples.size == 0:
                self.get_logger().warn('[Voxtral] Empty audio chunk received — ignoring.')
                return

            audio_np = samples.astype(np.float32) / 32768.0
            duration_s = audio_np.size / float(self._audio_sample_rate)
            self.get_logger().info(
                f'[Voxtral] Browser audio chunk: {samples.size} samples ({duration_s:.2f} s).')

            t_start = time.time()
            # Voxtral uses a mistral-common processor, not a Whisper-style one.
            # The supported transcription entry point is
            # `apply_transcrition_request` (note the typo in the method name —
            # that's how Mistral shipped it and HF transformers 4.55 kept it).
            # Some transformers versions may expose the corrected name as well.
            _apply = (getattr(self._processor, 'apply_transcription_request', None)
                      or getattr(self._processor, 'apply_transcrition_request'))
            # Write the audio to a temporary WAV file and pass the path — that's
            # the path documented in the Voxtral model card and is the most
            # stable contract. Passing np.ndarray directly hits a NoneType/len()
            # bug in mistral-common's audio handling in some 4.55 releases.
            import soundfile as sf
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                tmp_wav = tmp.name
            try:
                sf.write(tmp_wav, audio_np, self._audio_sample_rate,
                         format='WAV', subtype='PCM_16')
                inputs = _apply(
                    language='en',
                    audio=tmp_wav,
                    model_id=self._model_id,
                )
            finally:
                try:
                    os.unlink(tmp_wav)
                except OSError:
                    pass
            # Move every tensor to the model device (also handles BatchFeature).
            if hasattr(inputs, 'to'):
                inputs = inputs.to(self._model.device)
            else:
                inputs = {k: (v.to(self._model.device) if hasattr(v, 'to') else v)
                          for k, v in inputs.items()}

            # Remember the prompt length so we can strip it from the output.
            prompt_len = inputs['input_ids'].shape[1] if isinstance(inputs, dict) \
                         else inputs.input_ids.shape[1]

            with torch.inference_mode():
                ids = self._model.generate(
                    **(inputs if isinstance(inputs, dict) else dict(inputs)),
                    max_new_tokens=128,
                )

            # Slice off the prompt tokens — Voxtral emits [prompt..., response...]
            # and we only want the response text.
            transcript = self._processor.batch_decode(
                ids[:, prompt_len:], skip_special_tokens=True)[0].strip()
            inf_ms = (time.time() - t_start) * 1000.0

            if not transcript:
                self.get_logger().info(
                    f'[Voxtral] Browser audio transcribed as empty string ({inf_ms:.0f} ms). '
                    'Possibly silence or no speech.')
                return

            self.get_logger().info(
                f'[Voxtral] Transcript (browser, {inf_ms:.0f} ms): "{transcript}"')

            # Route through the same pipeline as text/local-mic so dashboard
            # sees the command and the LLaVA trigger flows as usual.
            fake_cmd = String()
            fake_cmd.data = transcript
            self._command_cb(fake_cmd)

        except Exception as e:
            self.get_logger().error(f'[Voxtral] _audio_chunk_cb error: {e}')
            self.get_logger().error(
                '[Voxtral] Traceback:\n' + traceback.format_exc())

    # ── Text simulation callbacks ──────────────────────────────────────

    def _command_cb(self, msg: String):
        """
        Process incoming text command (from operator or mic transcription).
        Routes to LLaVA if it's a scene question, or responds locally.
        """
        command = msg.data.strip()
        if not command:
            return

        t_recv = time.time()
        self.get_logger().info(f'[Voxtral] Command: {command}')

        # Publish transcript so the dashboard can show what was said
        transcript = String(); transcript.data = command
        self._pub_transcript.publish(transcript)

        # Decide if this is a scene question
        words = set(command.lower().replace('?', '').replace(',', '').split())
        is_scene_q = bool(words & SCENE_KEYWORDS)

        if is_scene_q:
            # Forward to LLaVA
            trigger = String(); trigger.data = command
            self._pub_llava.publish(trigger)
            with self._lock:
                self._pending_trigger_time = t_recv
            self.get_logger().info('[Voxtral] → Forwarded to LLaVA')
        else:
            # Handle locally: status / greeting / unknown
            response = self._local_response(command)
            resp_msg = String(); resp_msg.data = response
            self._pub_response.publish(resp_msg)

            latency_ms = (time.time() - t_recv) * 1000.0
            lat = Float32(); lat.data = float(latency_ms)
            self._pub_latency.publish(lat)

    def _llava_response_cb(self, msg: String):
        """Receive LLaVA answer and publish it as the voice response."""
        response = msg.data.strip()
        if not response:
            return

        resp_msg = String(); resp_msg.data = response
        self._pub_response.publish(resp_msg)

        with self._lock:
            if self._pending_trigger_time is not None:
                latency_ms = (time.time() - self._pending_trigger_time) * 1000.0
                lat = Float32(); lat.data = float(latency_ms)
                self._pub_latency.publish(lat)
                self._pending_trigger_time = None

        self.get_logger().info(f'[Voxtral] Response: {response[:80]}...')

    # ── Local responses (non-scene commands) ──────────────────────────

    def _local_response(self, command: str) -> str:
        cmd = command.lower()
        if any(w in cmd for w in ['hello', 'hola', 'hi', 'buenos días', 'buenas']):
            return 'Hello! I am the factory assistant. Ask me what you see in the camera.'
        if any(w in cmd for w in ['status', 'estado', 'ok', 'working', 'funcionando']):
            return 'All systems operational. YOLO detection and LLaVA reasoning are active.'
        if any(w in cmd for w in ['stop', 'para', 'detén', 'halt']):
            return 'Stop command received. Please use the Kubernetes control panel to halt pods.'
        return f'Command received: "{command}". For scene analysis, ask what you see.'


def main(args=None):
    rclpy.init(args=args)
    node = VoxtralNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
