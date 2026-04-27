# =============================================================================
#  ros2-voxtral — Voxtral Voice Interaction Node (GPU, FP16)
#  ROS 2 Humble | HuggingFace Transformers | Jetson L4T + amd64 CUDA
# =============================================================================
ARG ROS_DISTRO=humble
ARG TARGETARCH
ARG TORCH_VARIANT=auto

# --- Multi-stage: platform-specific CUDA libraries ---
# arm64 (Jetson): L4T JetPack has Jetson-native CUDA libs (SBSA libs don't work on Tegra iGPU)
# amd64: generic CUDA devel image for datacenter / desktop GPUs

FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS cuda-libs-arm64
COPY Models/cusparselt_stub.c /tmp/cusparselt_stub.c
RUN mkdir -p /cuda-export && \
    cp -a /usr/local/cuda/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    cp -a /usr/local/cuda/extras/CUPTI/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcudnn*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libnccl*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcusparseLt*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    if [ ! -f /cuda-export/libcusparseLt.so.0 ]; then \
      echo "Building libcusparseLt stub (not in JetPack)..." && \
      gcc -shared -o /cuda-export/libcusparseLt.so.0 /tmp/cusparselt_stub.c \
          -Wl,-soname,libcusparseLt.so.0 ; \
    fi

FROM nvcr.io/nvidia/cuda:12.6.3-cudnn-devel-ubuntu22.04 AS cuda-libs-amd64
RUN apt-get update && \
    apt-get install -y --no-install-recommends libcusparselt0 2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/*
RUN mkdir -p /cuda-export && \
    cp -a /usr/local/cuda/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    cp -a /usr/local/cuda/extras/CUPTI/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    find /usr/lib -name "libcudnn*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib -name "libnccl*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib -name "libcusparseLt*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true

FROM cuda-libs-${TARGETARCH} AS cuda-libs

FROM ros:${ROS_DISTRO}-ros-base
COPY Models/patch_torchvision_jetson.py /tmp/patch_torchvision_jetson.py

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42

# HuggingFace model cache — Voxtral weights are BAKED INTO THE IMAGE below
# (no runtime download required). Cache paths must match for both build and
# runtime so `from_pretrained(cache_dir=...)` finds the local snapshot.
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache
ENV HF_HUB_CACHE=/opt/huggingface_cache

# Default: text simulation. Set to true via Helm values to enable audio+GPU inference.
ENV VOXTRAL_AUDIO_MODE=false

# ── System dependencies ──────────────────────────────────────────────────────
# libasound2 / portaudio19 needed for mic capture (Audio mode)
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        python3-pip python3-colcon-common-extensions \
        libasound2 portaudio19-dev libopenblas0 \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# Copy CUDA 12.6 + cuDNN 9 runtime libs from NVIDIA stage
COPY --from=cuda-libs /cuda-export/ /usr/local/cuda/lib64/

# ── HuggingFace + audio deps (installed BEFORE PyTorch so pip doesn't overwrite the NVIDIA wheel)
#   NOTE: Voxtral (VoxtralForConditionalGeneration / VoxtralProcessor) landed in transformers 4.54.
#         LLaVA is NOT in this image, so we don't need the 4.48 pin that the shared images use.
#   NOTE: numpy must be in the 1.23-1.26 range. The Jetson PyTorch wheel
#         (2.5.0a0 nv24.08) is compiled against NumPy C-API 0x10 (NumPy 1.23-1.26,
#         NOT NumPy 2.0+ which is API 0x12). The ros:humble base ships NumPy 1.21
#         (API 0xe) — too old. NumPy 2.x — too new ("_ARRAY_API not found"). Both
#         break torch.from_numpy() and transformers disguises it as a misleading
#         "activate padding" error in BatchFeature.convert_to_tensors.
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir --upgrade \
      "transformers>=4.54,<4.56" \
      "accelerate>=0.34" \
      "numpy>=1.23,<2" \
      sounddevice \
      librosa \
      soundfile \
      mistral-common

# ── PyTorch — architecture-aware installation (MUST run AFTER deps to prevent pip overwrite)
#   arm64 (Jetson AGX Orin / JetPack 6.1, CUDA 12.6): NVIDIA pre-built wheel
#   amd64: standard CUDA 12.1 wheels from PyTorch
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps \
        "https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl" && \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchvision==0.20.0" && \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchaudio==2.5.0" || true && \
      python3 /tmp/patch_torchvision_jetson.py && \
      pip uninstall -y $(pip list 2>/dev/null | grep -i 'nvidia-cu' | awk '{print $1}' | tr '\n' ' ') 2>/dev/null || true ; \
    else \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 torchaudio==2.4.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    fi

# Jetson fix: patch transformers.generate() to skip FSDP / DeepSpeed check
#   The exact line differs between transformers 4.48 and 4.54+. We match broadly
#   (any synced_gpus assignment that references is_fsdp_managed_module or
#   is_deepspeed_zero3_enabled) and force the value to False. Build fails if no
#   matching line is found — that way a transformers bump that removes/renames
#   the check is caught immediately instead of crashing at runtime.
RUN python3 - <<'PY'
import re, sys
path = '/usr/local/lib/python3.10/dist-packages/transformers/generation/utils.py'
src = open(path).read()
pattern = re.compile(
    r'^([ \t]+)synced_gpus\s*=\s*[^\n]*(?:is_fsdp_managed_module|is_deepspeed_zero3_enabled)[^\n]*$',
    re.MULTILINE,
)
new_src, n = pattern.subn(r'\1synced_gpus = False  # patched for Jetson (no torch.distributed)', src)
if n == 0:
    print('[patch] ERROR: could not find synced_gpus assignment with FSDP/DeepSpeed check.')
    print('[patch] Dumping surrounding context for debugging:')
    for i, line in enumerate(src.splitlines(), 1):
        if 'synced_gpus' in line:
            print(f'  {i}: {line}')
    sys.exit(1)
open(path, 'w').write(new_src)
print(f'[patch] synced_gpus patched in {n} location(s).')
PY

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu/nvidia

# ── ROS 2 workspace ───────────────────────────────────────────────────────────
WORKDIR /opt/ros_ws
COPY Models/ros2_voxtral_ws/src/voxtral_pkg src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select voxtral_pkg

# ── Pre-download Voxtral model during build (embedded in image) ───────────────
# Voxtral-Mini-3B-2507 is a GATED Mistral model: you must accept the license on
# HuggingFace and provide your token at build time via a BuildKit secret:
#
#   export HF_TOKEN=hf_xxxxxxxxxxxxxxxxx
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --secret id=hf_token,env=HF_TOKEN \
#     --build-arg TORCH_VARIANT=auto \
#     --platform linux/arm64 \
#     -t $REG/ros2-voxtral:latest \
#     -f Models/ros2_voxtral_ws/docker/Dockerfile \
#     --provenance=false --load .
#
# Uses huggingface_hub.snapshot_download (no torch import) so the build runs
# fine under QEMU where CUDA libraries are absent. After this step the pod
# starts fully offline — see HF_HUB_OFFLINE=1 below.
RUN --mount=type=secret,id=hf_token,required=true \
    python3 -m pip install --no-cache-dir huggingface_hub && \
    mkdir -p /opt/huggingface_cache && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" HF_HUB_DISABLE_XET=1 python3 -c "\
import os; \
from huggingface_hub import snapshot_download; \
print('[build] Downloading Voxtral-Mini-3B-2507 (gated)...'); \
snapshot_download('mistralai/Voxtral-Mini-3B-2507', \
                  cache_dir='/opt/huggingface_cache', \
                  token=os.environ['HF_TOKEN']); \
print('[build] Voxtral model cached in image successfully.'); \
"

# Model is now embedded — forbid any runtime connection to HuggingFace Hub.
ENV HF_HUB_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1

# ── Resource monitor (CPU/GPU metrics publisher) ──────────────────────────────
COPY Models/ros2_voxtral_ws/scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY Models/ros2_voxtral_ws/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["ros2", "launch", "voxtral_pkg", "voxtral.launch.py"]
