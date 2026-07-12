# BYOM template, monolithic pattern.
# Extends the stock monolithic image and installs your package INTO the same
# workspace the chart already sources (/opt/ros2_monolithic_ws), replacing the
# perception slot in place. Build context: the repository root.
ARG BASE_REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG BASE_TAG=latest
FROM ${BASE_REGISTRY}/ros2-monolithic:${BASE_TAG}

# YOUR DEPS HERE: python dependencies of your model, for example:
# RUN python3 -m pip install --no-cache-dir onnxruntime-gpu
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"

COPY template/yolo_detector_pkg /tmp/user_src/yolo_detector_pkg
SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/humble/setup.bash && \
    cd /tmp/user_src && \
    colcon build --packages-select yolo_detector_pkg \
      --install-base /opt/ros2_monolithic_ws/install && \
    rm -rf /tmp/user_src build log
