# =============================================================================
#  ros2-voxtral — Voxtral-Mini-4B Voice Interaction Node
#  ROS 2 Humble | Text simulation mode (Phase 1) | Audio mode (Phase 2)
# =============================================================================
ARG ROS_DISTRO=humble
ARG TARGETARCH
ARG TORCH_VARIANT=auto
FROM ros:${ROS_DISTRO}-ros-base

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ENV ROS_DOMAIN_ID=42

# HuggingFace model cache (shared PVC — loaded only in audio mode)
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache

# Audio mode disabled by default (Phase 1 = text simulation)
ENV VOXTRAL_AUDIO_MODE=false

# ── System dependencies ──────────────────────────────────────────────────────
# libasound2 / portaudio19 needed for Phase 2 (mic capture)
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        python3-pip python3-colcon-common-extensions \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
        libasound2 portaudio19-dev \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# ── Python deps ───────────────────────────────────────────────────────────────
# Phase 1: minimal (no model loaded)
# Phase 2: transformers + sounddevice (add when enabling audio mode)
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir \
      numpy

# Uncomment for Phase 2 (audio mode):
# RUN python3 -m pip install --no-cache-dir \
#       torch==2.4.1 transformers==4.40.0 accelerate==0.30.0 \
#       bitsandbytes==0.43.1 sounddevice

# ── ROS 2 workspace ───────────────────────────────────────────────────────────
WORKDIR /opt/ros_ws
COPY src/voxtral_pkg src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    colcon build --symlink-install --packages-select voxtral_pkg

# Resource monitor (CPU/GPU metrics publisher)
COPY scripts/resource_monitor.py /opt/scripts/resource_monitor.py

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["ros2", "launch", "voxtral_pkg", "voxtral.launch.py"]
