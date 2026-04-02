ARG ROS_DISTRO=humble
ARG TORCH_VARIANT=auto
FROM ros:${ROS_DISTRO}-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42
ENV YOLO_VERBOSE=False

# HuggingFace cache (LLaVA model downloaded at runtime → cached in PVC)
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache

# Retry logic: QEMU arm64 emulation may segfault on libc-bin post-install
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
        v4l-utils \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# PyTorch (common base for YOLO + LLaVA)
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    if [ "${TORCH_VARIANT}" = "cuda121" ]; then \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    else \
      python3 -m pip install --no-cache-dir torch==2.4.1 torchvision==0.19.1 ; \
    fi

# YOLO + LLaVA Python dependencies
RUN python3 -m pip install --no-cache-dir \
      ultralytics==8.3.2 \
      transformers==4.44.0 \
      accelerate==0.33.0 \
      bitsandbytes==0.43.1 \
      Pillow \
      numpy

WORKDIR /opt/ros2_monolithic_ws
COPY Models/ros2_cam_ws/src/camera_driver_pkg     src/camera_driver_pkg
COPY Models/ros2_yolo_ws/src/yolo_detector_pkg    src/yolo_detector_pkg
COPY Models/ros2_llava_ws/src/llava_pkg           src/llava_pkg
COPY Models/ros2_voxtral_ws/src/voxtral_pkg       src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install \
      --packages-select camera_driver_pkg yolo_detector_pkg llava_pkg voxtral_pkg

# Pre-download YOLO model at build time (small: ~6MB)
RUN mkdir -p /opt/models && \
    python3 -c "from ultralytics import YOLO; YOLO('/opt/models/yolov8n.pt')"

# Pre-download LLaVA model during build (FP16 weights ~14GB).
# At runtime, bitsandbytes quantizes to 4-bit (~4GB VRAM).
# Zero network dependency at deploy time (factory / edge scenario).
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

# Standalone resource monitor
COPY Models/ros2_monolithic_ws/scripts/resource_monitor.py /opt/scripts/resource_monitor.py

COPY Models/ros2_monolithic_ws/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["/bin/bash","-lc","ros2 run camera_driver_pkg camera_driver & ros2 run yolo_detector_pkg yolo_detector && wait"]
