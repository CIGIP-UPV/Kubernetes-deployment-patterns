
# Imagen multi-arquitectura (amd64/arm64) con ROS 2 Humble
ARG ROS_DISTRO=humble
FROM ros:${ROS_DISTRO}-ros-base
LABEL authors="miguelangel"

# Paquetes de sistema/ROS necesarios para un paquete Python con OpenCV
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip python3-colcon-common-extensions \
    ros-${ROS_DISTRO}-cv-bridge ros-${ROS_DISTRO}-image-transport \
    ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
    python3-opencv v4l-utils libgl1 \
 && rm -rf /var/lib/apt/lists/*

# Workspace
ENV ROS_WS=/opt/ros2_cam_ws
WORKDIR ${ROS_WS}

# Copiamos el paquete del driver
COPY src/camera_driver_pkg ${ROS_WS}/src/camera_driver_pkg

# Compilamos (paquete Python; no compila C++)
SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install

# Entrypoint que hace source de ROS y del workspace
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Por defecto lanzamos el nodo (puedes cambiar a ros2 run si prefieres)
ENTRYPOINT ["/entrypoint.sh"]
CMD ["ros2", "launch", "camera_driver_pkg", "camera_driver.launch.py"]
