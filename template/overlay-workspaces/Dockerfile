# BYOM template, overlay workspaces pattern.
# Two stage build, matching the architecture split of this repository:
#   builder (arm64): compiles your package with ROS, because the overlay
#     payload executes on the arm64 edge node.
#   carrier (amd64): the delivery image; it only runs sh/tar on the amd64
#     cloud node, so its platform MUST be amd64 (see the incident notes in
#     Models/ros2_overlay_pack/docker/Dockerfile).
# Your package overwrites the perception slot inside /opt/overlay/install, so
# the runtime pod starts your model after fetching the overlay layer.
# Build with: docker build --platform linux/amd64 --provenance=false ...
# Build context: the repository root.
ARG BASE_REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG BASE_TAG=latest

FROM --platform=linux/arm64 ${BASE_REGISTRY}/ros2-base:${BASE_TAG} AS builder
# YOUR DEPS HERE: if your model needs python packages at runtime, install them
# with --target /opt/overlay_extra/python-deps so they travel in the carrier
# (see Models/ros2_overlay_pack/docker/Dockerfile for the full recipe).
RUN python3 -m pip install --no-cache-dir "setuptools<80" "packaging>=23,<25"
COPY template/yolo_detector_pkg /tmp/user_src/yolo_detector_pkg
SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/humble/setup.bash && \
    cd /tmp/user_src && \
    colcon build --packages-select yolo_detector_pkg \
      --install-base /opt/overlay_extra/install

FROM --platform=linux/amd64 ${BASE_REGISTRY}/ros2-overlay-pack:${BASE_TAG}
# Overwrites the perception slot files inside the carrier payload.
COPY --from=builder /opt/overlay_extra/install /opt/overlay/install
