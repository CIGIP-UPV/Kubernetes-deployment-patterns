# ROS 2 Humble (Ubuntu 22.04)
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

FROM busybox AS cuda-libs-amd64
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
ENV YOLO_VERBOSE=False

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
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# Copy CUDA 12.6 + cuDNN 9 runtime libs from NVIDIA image
COPY --from=cuda-libs /cuda-export/ /usr/local/cuda/lib64/

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
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchvision==0.20.0" && \
      python3 /tmp/patch_torchvision_jetson.py && \
      pip uninstall -y $(pip list 2>/dev/null | grep -i 'nvidia-cu' | awk '{print $1}' | tr '\n' ' ') 2>/dev/null || true ; \
    else \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1 torchvision==0.19.1 \
        --index-url https://download.pytorch.org/whl/cpu ; \
    fi

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu/nvidia

# Workspace
WORKDIR /opt/ros_ws
COPY Models/ros2_yolo_ws/src/yolo_detector_pkg src/yolo_detector_pkg

# instalar dependencias Python
RUN if [ -f src/yolo_detector_pkg/requirements.txt ]; then \
      python3 -m pip install --no-cache-dir -r src/yolo_detector_pkg/requirements.txt ; \
    fi

SHELL ["/bin/bash", "-lc"]
# Fix de deriva de dependencias (2026-07): la resolucion actual de pip instala
# setuptools>=80 (arrastrado por torch), que rompe colcon-core (<80) y choca
# con packaging antiguo (canonicalize_version strip_trailing_zero). Se fija
# setuptools<80 + packaging moderno ANTES de colcon build.
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"
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
COPY Models/ros2_yolo_ws/scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# Entrypoint
COPY Models/ros2_yolo_ws/docker/entrypoint.sh /entrypoint.sh
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
