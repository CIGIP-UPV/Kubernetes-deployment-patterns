# ─────────────────────────────────────────────────────────
#  ROS 2 Dashboard — rosbridge + HTTP server
#  Multi-arch: linux/amd64 + linux/arm64
# ─────────────────────────────────────────────────────────
FROM ros:humble-ros-base

# Retry logic: QEMU arm64 emulation may segfault on libc-bin post-install
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        ros-humble-rosbridge-suite \
        ros-humble-rmw-cyclonedds-cpp \
        ros-humble-vision-msgs \
        python3 \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; \
           apt-get install -f -y || true; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# Pre-bundle roslib.js in /opt/dashboard-lib (outside ConfigMap mount point)
# The entrypoint copies these into /dashboard/lib/ at startup
RUN mkdir -p /opt/dashboard-lib /dashboard && \
    for attempt in 1 2 3; do \
      apt-get update && \
      apt-get install -y --no-install-recommends curl ca-certificates && break \
      || { apt-get install -f -y || true; sleep 2; }; \
    done && \
    curl -fsSL -o /opt/dashboard-lib/roslib.min.js \
      https://cdnjs.cloudflare.com/ajax/libs/roslibjs/1.1.0/roslib.min.js && \
    apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

EXPOSE 8080 9090

# Default entrypoint: sourced ROS env
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
