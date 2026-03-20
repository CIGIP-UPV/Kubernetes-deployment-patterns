ARG ROS_DISTRO=humble
ARG TORCH_VARIANT=auto
FROM ros:${ROS_DISTRO}-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42
ENV YOLO_VERBOSE=False

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-pip python3-colcon-common-extensions \
      python3-opencv libgl1 libglib2.0-0 \
      ros-${ROS_DISTRO}-cv-bridge \
      ros-${ROS_DISTRO}-vision-msgs \
      ros-${ROS_DISTRO}-image-transport \
      ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
      v4l-utils \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    if [ "${TORCH_VARIANT}" = "cuda121" ]; then \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    else \
      python3 -m pip install --no-cache-dir torch==2.4.1 torchvision==0.19.1 ; \
    fi && \
    python3 -m pip install --no-cache-dir ultralytics==8.3.2 numpy

WORKDIR /opt/ros2_monolithic_ws
COPY Models/ros2_cam_ws/src/camera_driver_pkg src/camera_driver_pkg
COPY Models/ros2_yolo_ws/src/yolo_detector_pkg src/yolo_detector_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select camera_driver_pkg yolo_detector_pkg

RUN mkdir -p /opt/models && \
    python3 -c "from ultralytics import YOLO; YOLO('/opt/models/yolov8n.pt')"

COPY Models/ros2_monolithic_ws/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["/bin/bash","-lc","ros2 run camera_driver_pkg camera_driver & ros2 run yolo_detector_pkg yolo_detector && wait"]
