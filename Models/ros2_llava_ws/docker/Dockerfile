# =============================================================================
#  ros2-llava — LLaVA-1.5-7b Visual Reasoning Node
#  ROS 2 Humble | HuggingFace Transformers | 4-bit quantization (bitsandbytes)
# =============================================================================
ARG ROS_DISTRO=humble
ARG TARGETARCH
ARG TORCH_VARIANT=auto
FROM ros:${ROS_DISTRO}-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42

# HuggingFace model cache — model is pre-downloaded during build
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache

# ── System dependencies ──────────────────────────────────────────────────────
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        python3-pip python3-colcon-common-extensions \
        python3-opencv libgl1 libglib2.0-0 \
        ros-${ROS_DISTRO}-cv-bridge \
        ros-${ROS_DISTRO}-vision-msgs \
        ros-${ROS_DISTRO}-image-transport \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# ── PyTorch ──────────────────────────────────────────────────────────────────
# arm64 (Jetson): uses PyTorch pre-installed by JetPack or CPU wheels
# amd64: cuda121 for GPU-enabled builds
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    if [ "${TORCH_VARIANT}" = "cuda121" ]; then \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    else \
      python3 -m pip install --no-cache-dir torch==2.4.1 torchvision==0.19.1 ; \
    fi

# ── HuggingFace + LLaVA deps ─────────────────────────────────────────────────
RUN python3 -m pip install --no-cache-dir \
      transformers==4.40.0 \
      accelerate==0.30.0 \
      bitsandbytes==0.43.1 \
      Pillow \
      numpy

# ── ROS 2 workspace ───────────────────────────────────────────────────────────
WORKDIR /opt/ros_ws
COPY src/llava_pkg src/llava_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select llava_pkg

# ── Pre-download LLaVA model during build (embedded in image) ─────────────────
# Downloads FP16 weights (~14GB). At runtime, bitsandbytes quantizes to 4-bit.
# This ensures zero network dependency at deploy time (factory / edge scenario).
RUN mkdir -p /opt/huggingface_cache && \
    python3 -c "\
from transformers import AutoProcessor, LlavaForConditionalGeneration; \
import torch; \
print('[build] Downloading LLaVA processor...'); \
AutoProcessor.from_pretrained('llava-hf/llava-1.5-7b-hf', cache_dir='/opt/huggingface_cache'); \
print('[build] Downloading LLaVA model weights (FP16)...'); \
LlavaForConditionalGeneration.from_pretrained('llava-hf/llava-1.5-7b-hf', cache_dir='/opt/huggingface_cache', torch_dtype=torch.float16, low_cpu_mem_usage=True); \
print('[build] LLaVA model cached successfully.'); \
"

# ── Resource monitor ──────────────────────────────────────────────────────────
COPY scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["ros2", "launch", "llava_pkg", "llava.launch.py"]
