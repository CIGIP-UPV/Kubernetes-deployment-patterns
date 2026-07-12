# BYOM template, microservices pattern.
# Extends ONLY the perception service image (ros2-yolo); the other services
# stay stock. Your package replaces the slot inside /opt/ros_ws, the workspace
# the yolo statefulset command sources. Build context: the repository root.
ARG BASE_REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG BASE_TAG=latest
FROM ${BASE_REGISTRY}/ros2-yolo:${BASE_TAG}

# YOUR DEPS HERE
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"

COPY template/yolo_detector_pkg /tmp/user_src/yolo_detector_pkg
SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/humble/setup.bash && \
    cd /tmp/user_src && \
    colcon build --packages-select yolo_detector_pkg \
      --install-base /opt/ros_ws/install && \
    rm -rf /tmp/user_src build log
