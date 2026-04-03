# ROS 2 Humble (Ubuntu 22.04)
ARG ROS_DISTRO=humble
ARG TARGETARCH
ARG TORCH_VARIANT=auto
FROM ros:${ROS_DISTRO}-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42
ENV YOLO_VERBOSE=False

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
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# PyTorch — architecture-aware installation
#   arm64 (Jetson AGX Orin / JetPack 6.1, CUDA 12.6): NVIDIA pre-built wheel
#   amd64: standard CUDA 12.1 wheels from PyTorch
# Python dependencies (installed BEFORE PyTorch so they don't overwrite the NVIDIA wheel)
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir \
      ultralytics==8.3.2 \
      numpy \
      fastapi==0.115.6 \
      uvicorn==0.32.1 \
      python-multipart==0.0.17

# PyTorch — architecture-aware installation (MUST run AFTER deps to prevent pip overwrite)
#   arm64 (Jetson AGX Orin / JetPack 6.1, CUDA 12.6): NVIDIA pre-built wheel
#   amd64: standard CUDA 12.1 wheels from PyTorch
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps \
        "https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl" && \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps torchvision && \
      pip uninstall -y $(pip list 2>/dev/null | grep -i 'nvidia-cu' | awk '{print $1}' | tr '\n' ' ') 2>/dev/null || true ; \
    else \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    fi

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu/nvidia:${LD_LIBRARY_PATH}

# Workspace
WORKDIR /opt/ros_ws
COPY src/yolo_detector_pkg src/yolo_detector_pkg

# instalar dependencias Python
RUN if [ -f src/yolo_detector_pkg/requirements.txt ]; then \
      python3 -m pip install --no-cache-dir -r src/yolo_detector_pkg/requirements.txt ; \
    fi

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select yolo_detector_pkg

# Pre-download the model during build so runtime validation does not depend on network access.
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

# Standalone resource monitor (no colcon build needed — uses rclpy directly)
COPY scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# Entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

# Lanza el detector
CMD ["ros2", "launch", "yolo_detector_pkg", "yolo_detector.launch.py"]

# ======= CPU (opcional) =======
# Sustituye el bloque "PyTorch + CUDA" por:
# RUN python3 -m pip install --no-cache-dir --upgrade pip && \
#     python3 -m pip install --no-cache-dir \
#       torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cpu && \
#     python3 -m pip install --no-cache-dir ultralytics==8.3.2 numpy
