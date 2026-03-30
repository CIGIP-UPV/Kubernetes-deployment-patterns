# ─────────────────────────────────────────────────────────
#  ROS 2 Dashboard — rosbridge + HTTP server
#  Multi-arch: linux/amd64 + linux/arm64
# ─────────────────────────────────────────────────────────
FROM ros:humble-ros-base

RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-humble-rosbridge-suite \
        ros-humble-rmw-cyclonedds-cpp \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Dashboard HTML is mounted via ConfigMap at /dashboard
RUN mkdir -p /dashboard

EXPOSE 8080 9090

# Default entrypoint: sourced ROS env
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
