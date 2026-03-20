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

# Dependencias del sistema y ROS
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-pip python3-colcon-common-extensions \
      python3-opencv libgl1 libglib2.0-0 \
      ros-${ROS_DISTRO}-cv-bridge \
      ros-${ROS_DISTRO}-vision-msgs \
      ros-${ROS_DISTRO}-image-transport \
      ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
    && rm -rf /var/lib/apt/lists/*

# Use CPU wheels on arm64/local validation, and allow explicit CUDA on amd64.
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    if [ "${TORCH_VARIANT}" = "cuda121" ]; then \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    else \
      python3 -m pip install --no-cache-dir torch==2.4.1 torchvision==0.19.1 ; \
    fi && \
    python3 -m pip install --no-cache-dir \
      ultralytics==8.3.2 \
      numpy \
      fastapi==0.115.6 \
      uvicorn==0.32.1 \
      python-multipart==0.0.17

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
RUN mkdir -p /opt/models && \
    python3 -c "from ultralytics import YOLO; YOLO('/opt/models/yolov8n.pt')"

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
