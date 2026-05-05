# =============================================================================
#  ros2-base — Canonical Overlay Pattern Base Image
#  ROS 2 Humble | Camera driver | CUDA hardware abstraction (Jetson L4T)
#
#  Per the Overlay Workspaces theory ("the base layer can be a proven read-only
#  platform, while the overlay layers are the only parts that change"), this
#  image is the IMMUTABLE trusted platform. It contains only:
#
#    • ROS 2 Humble core + CycloneDDS transport
#    • camera_driver_pkg (sensor driver — hardware-tied)
#    • CUDA L4T runtime libs (Jetson-native, NOT generic SBSA)
#    • numpy 1.26 (required by ROS 2 sensor_msgs at runtime AND
#      compatible with the Jetson PyTorch wheel that overlay-pack ships)
#
#  Deliberately NOT here:
#    • PyTorch, transformers, accelerate, bitsandbytes  →  go in overlay-pack
#    • mistral-common, sounddevice, librosa             →  go in overlay-pack
#    • yolo_detector_pkg, llava_pkg, voxtral_pkg        →  go in overlay-pack
#    • LLaVA / Voxtral model weights                    →  go in overlay-pack
#
#  Size target: ~3-4 GB (vs ~22 GB for ros2-monolithic).
#
#  Consumed by:
#    1) ros2-overlay-pack (FROM ros2-base, adds ML stack + AI nodes + models)
#    2) Patterns/overlay-canonical StatefulSet (uses this image directly,
#       mounts the overlay artifacts at /opt/overlay via emptyDir)
# =============================================================================
ARG ROS_DISTRO=humble
ARG TARGETARCH

# --- Multi-stage: platform-specific CUDA libraries ---
# arm64 (Jetson): L4T JetPack has Jetson-native CUDA libs. Generic SBSA libs
#                 from nvcr.io/nvidia/cuda:* are INCOMPATIBLE with Tegra iGPU.
# amd64:          generic CUDA devel image for datacenter / desktop dev.
#
# This pattern (multi-stage CUDA + arch-conditional FROM) is the same one
# already validated in ros2-voxtral, ros2-llava, ros2-monolithic, ros2-overlay.

FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0 AS cuda-libs-arm64
COPY Models/cusparselt_stub.c /tmp/cusparselt_stub.c
RUN mkdir -p /cuda-export && \
    cp -a /usr/local/cuda/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    cp -a /usr/local/cuda/extras/CUPTI/lib64/*.so* /cuda-export/ 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcudnn*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libnccl*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    find /usr/lib/aarch64-linux-gnu -name "libcusparseLt*.so*" -exec cp -a {} /cuda-export/ \; 2>/dev/null || true && \
    if [ ! -f /cuda-export/libcusparseLt.so.0 ]; then \
      echo "Building libcusparseLt stub (not in JetPack 6.1)..." && \
      gcc -shared -o /cuda-export/libcusparseLt.so.0 /tmp/cusparselt_stub.c \
          -Wl,-soname,libcusparseLt.so.0 ; \
    fi

FROM nvcr.io/nvidia/cuda:12.6.3-cudnn-devel-ubuntu22.04 AS cuda-libs-amd64
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

# --- Final stage: ROS 2 Humble base + camera driver --------------------------
FROM ros:${ROS_DISTRO}-ros-base

# patch_torchvision_jetson.py is staged here for completeness — it's needed
# by overlay-pack's torchvision install. Including it in the base means
# overlay-pack doesn't need to COPY it from the build context (which would
# make overlay-pack's build context broader than necessary).
COPY Models/patch_torchvision_jetson.py /tmp/patch_torchvision_jetson.py

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42

# ── System dependencies ──────────────────────────────────────────────────────
# Minimal set:
#   • python3-pip, python3-colcon-common-extensions  → required to compile
#     camera_driver_pkg with `colcon build`
#   • libopenblas0  → small (~30 MB), used by numpy and any future CPU math.
#     Could be removed if size is critical, but it's a common ROS 2 dep.
#   • ros-humble-rmw-cyclonedds-cpp  → DDS implementation (Cyclone, not Fast-RTPS).
#     Same choice as the rest of the patterns.
#   • libv4l-dev, v4l-utils  → needed by camera_driver_pkg to access /dev/video*.
#
# Retry loop (3 attempts) is a defensive pattern from QEMU emulation builds
# where libc-bin postinst occasionally segfaults on first run. Same pattern
# as in the other Dockerfiles.
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        python3-pip python3-colcon-common-extensions \
        libopenblas0 \
        libv4l-dev v4l-utils \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
        ros-${ROS_DISTRO}-cv-bridge \
        ros-${ROS_DISTRO}-image-transport \
        ros-${ROS_DISTRO}-vision-msgs \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && \
    # Loud check: if vision_msgs failed silently (apt retry loop swallows
    # "Unable to locate package" exit codes), fail the build now.
    dpkg -s ros-${ROS_DISTRO}-vision-msgs >/dev/null 2>&1 || \
      { echo "[apt] FATAL: ros-${ROS_DISTRO}-vision-msgs not installed"; exit 1; } && \
    rm -rf /var/lib/apt/lists/*

# ── Copy CUDA 12.6 + cuDNN 9 runtime libs from the multi-stage above ─────────
# Even though base has no PyTorch, having CUDA libs here means the overlay-pack
# (which DOES have PyTorch) doesn't need to re-do this multi-stage. Saves time
# on overlay rebuilds. CUDA libs are tied to JetPack 6.1 hardware platform
# and considered immutable (matches "trusted base" theory).
COPY --from=cuda-libs /cuda-export/ /usr/local/cuda/lib64/

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu/nvidia

# ── numpy 1.26 (compatible with Jetson PyTorch wheel) ────────────────────────
# numpy>=1.23,<2 — see CLAUDE.md "Errors solved" section.
# The Jetson PyTorch wheel (2.5.0a0 nv24.08) is compiled against NumPy 1.x
# C-API (0x10 = NumPy 1.23-1.26). Even though base has no PyTorch, ROS 2
# sensor_msgs uses numpy at runtime, AND when overlay-pack inherits this base
# its PyTorch will not work if numpy is 2.x.
#
# Use --upgrade so pip overwrites the apt-installed 1.21 that ships with the
# ros:humble-ros-base image (otherwise pip skips because "numpy already
# installed", and 1.21 is too old for the Jetson wheel).
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir --upgrade "numpy>=1.23,<2"

# ── ROS 2 base workspace: camera driver only ─────────────────────────────────
# /opt/base_ws is the BASE workspace per ROS 2 overlay theory. It builds
# camera_driver_pkg (the only package in base, since it's a hardware-tied
# sensor driver — see PLAN section 2.4 for the rationale).
WORKDIR /opt/base_ws
COPY Models/ros2_cam_ws/src/camera_driver_pkg src/camera_driver_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select camera_driver_pkg

# ── Resource monitor (CPU/RAM/GPU/I/O/Power telemetry for the dashboard) ─────
# Standalone script — both canonical patterns (overlay-canonical runtime and
# dynamic-canonical component-host) launch it as a background process. It
# publishes /node/cpu_percent, /node/memory_percent, /node/gpu_percent,
# /node/io_read_mbs, /node/io_write_mbs, and /node/power_mw (Jetson tegrastats).
# Same script as the one in ros2-monolithic / ros2-yolo / ros2-llava / ros2-voxtral.
COPY Models/ros2_monolithic_ws/scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# ── Default shell environment ────────────────────────────────────────────────
# Auto-source ROS 2 setup + base workspace so an interactive shell sees them.
# The overlay (when mounted at /opt/overlay) will be sourced explicitly by
# the StatefulSet's command, NOT here, because base must work without an
# overlay being present.
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /etc/bash.bashrc && \
    echo "source /opt/base_ws/install/setup.bash"  >> /etc/bash.bashrc

# Note: NO ENTRYPOINT, NO CMD here.
# This image is consumed in two ways:
#   1) `FROM ros2-base` in ros2-overlay-pack: the overlay-pack defines its own
#      entrypoint (which is just `cp` for the carrier role, see Dockerfile).
#   2) Direct use by the StatefulSet of overlay-canonical: the Helm chart
#      provides command + args that source base+overlay setup.bash and launch
#      the four ROS 2 nodes in background.
