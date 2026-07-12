# BYOM template, dynamic module loading pattern.
# Extends the component host image. Your package replaces the perception slot
# inside /opt/component_ws, so the plugin entry point
# yolo_detector_pkg::YoloDetector now resolves to YOUR class and the
# orchestrator loads and unloads it under the existing module name "yolo"
# with no orchestrator edits. Build context: the repository root.
ARG BASE_REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG BASE_TAG=latest
FROM ${BASE_REGISTRY}/ros2-component-host:${BASE_TAG}

# YOUR DEPS HERE
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"

COPY template/yolo_detector_pkg /tmp/user_src/yolo_detector_pkg
SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/humble/setup.bash && \
    source /opt/base_ws/install/setup.bash && \
    cd /tmp/user_src && \
    colcon build --packages-select yolo_detector_pkg \
      --install-base /opt/component_ws/install && \
    rm -rf /tmp/user_src build log

# Loud check: the plugin must be discoverable or the bootstrap will fail.
RUN source /opt/ros/humble/setup.bash && \
    source /opt/component_ws/install/setup.bash && \
    python3 -c "\
from importlib.metadata import entry_points; \
eps = [e for e in entry_points().get('rclpy_components', []) \
       if e.name == 'yolo_detector_pkg::YoloDetector']; \
assert eps, 'plugin entry point not found'; \
print('[build] plugin OK:', eps[0].value)"
