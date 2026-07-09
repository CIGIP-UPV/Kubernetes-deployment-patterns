ARG ROS_DISTRO=humble
ARG TORCH_VARIANT=auto
ARG TARGETARCH

# --- Multi-stage: platform-specific CUDA libraries ---
# arm64 (Jetson): L4T JetPack image has Jetson-native CUDA, cuDNN, cuBLAS etc.
#   Generic SBSA (server ARM) libs do NOT work on Jetson's integrated Tegra GPU.
# amd64: generic CUDA devel image for datacenter / desktop GPUs.

FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS cuda-libs-arm64
COPY Models/cusparselt_stub.c /tmp/cusparselt_stub.c
RUN mkdir -p /cuda-export && \
    cp -a /usr/local/cuda/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    cp -a /usr/local/cuda/extras/CUPTI/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcudnn*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libnccl*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcusparseLt*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    # cuSPARSELt: not in JetPack repos — build stub from source if not found \
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

# Torchvision Jetson patch script (fixes CUDA 13 vs 12.6 incompatibility)
COPY Models/patch_torchvision_jetson.py /tmp/patch_torchvision_jetson.py

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42
ENV YOLO_VERBOSE=False

# HuggingFace cache — LLaVA and Voxtral weights are BAKED INTO THE IMAGE below.
# Cache paths must match for build and runtime so from_pretrained(cache_dir=...)
# finds the local snapshot; HF_HUB_OFFLINE at the end blocks any network call.
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache
ENV HF_HUB_CACHE=/opt/huggingface_cache

# Retry logic: QEMU arm64 emulation may segfault on libc-bin post-install
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        python3-pip python3-colcon-common-extensions \
        python3-opencv libgl1 libglib2.0-0 libopenblas0 \
        ros-${ROS_DISTRO}-cv-bridge \
        ros-${ROS_DISTRO}-vision-msgs \
        ros-${ROS_DISTRO}-image-transport \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
        v4l-utils \
        libasound2 portaudio19-dev libsndfile1 \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# Copy CUDA 12.6 + cuDNN 9 runtime libs from NVIDIA image (needed on Jetson
# where the nvidia runtime mounts only the driver, not the CUDA toolkit)
COPY --from=cuda-libs /cuda-export/ /usr/local/cuda/lib64/

# YOLO + LLaVA + Voxtral Python dependencies (installed BEFORE PyTorch so they don't overwrite the NVIDIA wheel)
#   numpy must be in the 1.23-1.26 range. The Jetson PyTorch wheel (2.5.0a0 nv24.08)
#   is compiled against NumPy C-API 0x10 (NumPy 1.23-1.26, NOT 2.x which is 0x12).
#   The ros:humble base ships NumPy 1.21 (API 0xe) — too old. NumPy 2.x — too new
#   ("_ARRAY_API not found"). Both break torch.from_numpy() and transformers
#   disguises it as a misleading "activate padding" error.
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir --upgrade \
      ultralytics==8.3.2 \
      "transformers>=4.48,<4.49" \
      "accelerate>=0.34" \
      bitsandbytes \
      Pillow \
      "numpy>=1.23,<2" \
      sounddevice \
      librosa \
      soundfile \
      mistral-common

# PyTorch — architecture-aware installation (MUST run AFTER deps to prevent pip overwrite)
#   arm64 (Jetson AGX Orin / JetPack 6.1, CUDA 12.6): NVIDIA pre-built wheel
#   amd64: standard CUDA 12.1 wheels from PyTorch
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      # 1. Install NVIDIA Jetson torch wheel
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps \
        "https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl" && \
      # 2. Install torchvision binary + patch for Jetson CUDA 12.6 compatibility
      #    PyPI binary needs libcudart.so.13 (CUDA 13) but Jetson has CUDA 12.6.
      #    Patch disables _meta_registrations and adds pure-PyTorch NMS fallback.
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchvision==0.20.0" && \
      python3 /tmp/patch_torchvision_jetson.py && \
      # 2b. torchaudio (needed by Voxtral) — best-effort on Jetson; harmless if the
      #     prebuilt wheel is missing since voxtral falls back to text-sim then.
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchaudio==2.5.0" || true && \
      # 3. Remove pip nvidia packages (not available on arm64 anyway)
      pip uninstall -y $(pip list 2>/dev/null | grep -i 'nvidia-cu' | awk '{print $1}' | tr '\n' ' ') 2>/dev/null || true ; \
    else \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 torchaudio==2.4.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    fi

# Jetson fix: transformers 4.48 calls is_fsdp_managed_module() in generate(),
# which cascades into torch.distributed.fsdp — not available on Jetson.
# Patch synced_gpus to False (only needed for multi-GPU distributed training).
RUN sed -i 's/synced_gpus = (is_deepspeed_zero3_enabled() or is_fsdp_managed_module(self)) and dist.get_world_size() > 1/synced_gpus = False/' \
    /usr/local/lib/python3.10/dist-packages/transformers/generation/utils.py

# CUDA library paths — on Jetson the nvidia-cdi runtime mounts host CUDA libs;
# on amd64 the pip nvidia-cu* packages provide them.
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu/nvidia

WORKDIR /opt/ros2_monolithic_ws
COPY Models/ros2_cam_ws/src/camera_driver_pkg     src/camera_driver_pkg
COPY Models/ros2_yolo_ws/src/yolo_detector_pkg    src/yolo_detector_pkg
COPY Models/ros2_llava_ws/src/llava_pkg           src/llava_pkg
COPY Models/ros2_voxtral_ws/src/voxtral_pkg       src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
# Fix de deriva de dependencias (2026-07): setuptools>=80 (arrastrado por torch)
# rompe colcon-core (<80) y choca con packaging antiguo. Fijar antes de colcon.
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install \
      --packages-select camera_driver_pkg yolo_detector_pkg llava_pkg voxtral_pkg

# Pre-download YOLO model at build time (small: ~6MB)
# On arm64 the NVIDIA torch requires CUDA libs that are absent under QEMU,
# so we download the weights with urllib instead of importing ultralytics.
RUN mkdir -p /opt/models && \
    ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      python3 -c "\
import urllib.request, os; \
url='https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt'; \
dst='/opt/models/yolov8n.pt'; \
print('[build] Downloading YOLOv8n weights...'); \
urllib.request.urlretrieve(url, dst); \
print(f'[build] Saved {os.path.getsize(dst)/1e6:.1f} MB to {dst}'); \
" ; \
    else \
      python3 -c "from ultralytics import YOLO; YOLO('/opt/models/yolov8n.pt')" ; \
    fi

# Pre-download LLaVA model during build.
# Uses huggingface_hub.snapshot_download (no torch import) so the build works
# under QEMU where CUDA libraries are absent.
RUN python3 -m pip install --no-cache-dir huggingface_hub && \
    mkdir -p /opt/huggingface_cache && \
    HF_HUB_DISABLE_XET=1 python3 -c "\
from huggingface_hub import snapshot_download; \
print('[build] Downloading LLaVA model files...'); \
snapshot_download('llava-hf/llava-1.5-7b-hf', cache_dir='/opt/huggingface_cache'); \
print('[build] LLaVA model cached successfully.'); \
"

# Pre-download Voxtral-Mini-3B-2507 (gated). Requires HF_TOKEN via BuildKit:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --secret id=hf_token,env=HF_TOKEN \
#     --build-arg TORCH_VARIANT=auto --platform linux/arm64 \
#     -t $REG/ros2-monolithic:latest \
#     -f Models/ros2_monolithic_ws/docker/Dockerfile \
#     --provenance=false --load .
RUN --mount=type=secret,id=hf_token,required=true \
    mkdir -p /opt/huggingface_cache && \
    HF_TOKEN="$(cat /run/secrets/hf_token)" HF_HUB_DISABLE_XET=1 python3 -c "\
import os, sys; \
from huggingface_hub import snapshot_download; \
tok = os.environ.get('HF_TOKEN', ''); \
print(f'[build] HF_TOKEN length: {len(tok)} (must be > 0)'); \
assert len(tok) > 10, '[build] FATAL: HF_TOKEN empty or too short — secret not passed correctly'; \
print('[build] Downloading Voxtral-Mini-3B-2507 (gated)...'); \
local_dir = snapshot_download('mistralai/Voxtral-Mini-3B-2507', \
                              cache_dir='/opt/huggingface_cache', \
                              token=tok); \
print(f'[build] snapshot_download returned: {local_dir}'); \
" && \
    SIZE_KB=$(du -sk /opt/huggingface_cache/models--mistralai--Voxtral-Mini-3B-2507/ 2>/dev/null | awk '{print $1}') && \
    echo "[build] Voxtral cache size: ${SIZE_KB} KB" && \
    if [ -z "$SIZE_KB" ] || [ "$SIZE_KB" -lt 1000000 ]; then \
      echo "[build] FATAL: Voxtral cache size too small (${SIZE_KB} KB < 1 GB). Token rejected or download failed." ; \
      ls -laR /opt/huggingface_cache/models--mistralai--Voxtral-Mini-3B-2507/ ; \
      exit 1 ; \
    fi && \
    echo "[build] Voxtral model verified: ${SIZE_KB} KB cached."

# Both models are embedded — forbid runtime connections to HuggingFace Hub.
ENV HF_HUB_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1

# Standalone resource monitor
COPY Models/ros2_monolithic_ws/scripts/resource_monitor.py /opt/scripts/resource_monitor.py

COPY Models/ros2_monolithic_ws/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["/bin/bash","-lc","ros2 run camera_driver_pkg camera_driver & ros2 run yolo_detector_pkg yolo_detector && wait"]
