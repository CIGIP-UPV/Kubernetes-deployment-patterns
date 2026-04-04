"""
Voxtral interaction node — ROS 2 / Kubernetes Deployment Patterns
=================================================================

Mode A — TEXT SIMULATION (default, VOXTRAL_AUDIO_MODE=false):
  The operator sends text commands via the /voice/command topic.
  The node routes questions to LLaVA and publishes responses to /voice/response.
  No audio hardware required. Useful for initial integration testing.

Mode B — AUDIO (VOXTRAL_AUDIO_MODE=true):
  Captures audio from a USB/ALSA microphone (e.g., camera built-in mic).
  Loads the Voxtral-Mini-4B-Realtime model for speech recognition.
  Publishes transcripts and forwards scene questions to LLaVA.
  (Phase 2 — microphone hardware required)

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

import rclpy
from rclpy.node import Node
from std_msgs.msg import String, Float32
import time
import threading


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
        self.declare_parameter('model_id',            'mistralai/Voxtral-Mini-4B-Realtime-2602')
        self.declare_parameter('command_topic',       '/voice/command')
        self.declare_parameter('transcript_topic',    '/voice/transcript')
        self.declare_parameter('response_topic',      '/voice/response')
        self.declare_parameter('llava_trigger_topic', '/llava/trigger')
        self.declare_parameter('llava_response_topic','/llava/response')
        self.declare_parameter('latency_topic',       '/voice/metrics_latency_ms')
        self.declare_parameter('hf_cache_dir',        '/opt/huggingface_cache')

        self._audio_mode = self.get_parameter('audio_mode').value
        self._pending_trigger_time: float | None = None
        self._lock = threading.Lock()

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
        cache_dir = self.get_parameter('hf_cache_dir').value

        self.get_logger().info(f'[Voxtral] Loading model {model_id} ...')
        try:
            import torch
            from transformers import AutoProcessor, AutoModelForSpeechSeq2Seq, BitsAndBytesConfig

            # ── GPU diagnostic ───────────────────────────────────────
            cuda_ok = torch.cuda.is_available()
            self.get_logger().info(f'[Voxtral] torch.cuda.is_available() = {cuda_ok}')
            if cuda_ok:
                self.get_logger().info(
                    f'[Voxtral] GPU: {torch.cuda.get_device_name(0)} | '
                    f'CUDA {torch.version.cuda} | '
                    f'VRAM {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')
            else:
                self.get_logger().warn('[Voxtral] CUDA not available — model will run on CPU (slow!)')

            quant_cfg = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_compute_dtype=torch.float16,
            )
            self._processor = AutoProcessor.from_pretrained(model_id, cache_dir=cache_dir)
            self._model = AutoModelForSpeechSeq2Seq.from_pretrained(
                model_id,
                cache_dir=cache_dir,
                quantization_config=quant_cfg,
                device_map='auto',
                torch_dtype=torch.float16,
                low_cpu_mem_usage=True,
            )
            self._model.eval()
            self.get_logger().info('[Voxtral] Model loaded. Starting mic capture...')
            self._start_mic_thread()
        except Exception as e:
            self.get_logger().error(f'[Voxtral] Failed to load model: {e}')
            self.get_logger().warn('[Voxtral] Falling back to TEXT SIMULATION mode.')
            self._audio_mode = False

    def _start_mic_thread(self):
        """Background thread for real-time microphone capture."""
        t = threading.Thread(target=self._mic_loop, daemon=True)
        t.start()

    def _mic_loop(self):
        """
        Capture audio from ALSA device and transcribe with Voxtral.
        Requires: pyaudio or sounddevice + the ALSA device mounted in the container.
        Phase 2 — implemented when microphone is confirmed working.
        """
        try:
            import sounddevice as sd
            import numpy as np
            import torch

            SAMPLE_RATE = 16000
            CHUNK_S     = 3      # seconds per chunk
            CHUNK_SAMPS = SAMPLE_RATE * CHUNK_S

            self.get_logger().info(f'[Voxtral] Mic loop started. SR={SAMPLE_RATE}, chunk={CHUNK_S}s')

            while rclpy.ok():
                audio = sd.rec(CHUNK_SAMPS, samplerate=SAMPLE_RATE,
                               channels=1, dtype='float32')
                sd.wait()
                audio_np = audio.squeeze()

                inputs = self._processor(
                    audio_np, sampling_rate=SAMPLE_RATE, return_tensors='pt'
                ).to(self._model.device)

                with torch.inference_mode():
                    ids = self._model.generate(**inputs, max_new_tokens=128)

                text = self._processor.batch_decode(ids, skip_special_tokens=True)[0].strip()

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
