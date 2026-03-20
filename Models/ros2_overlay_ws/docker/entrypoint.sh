#!/usr/bin/env bash
set -e
source /opt/ros/${ROS_DISTRO}/setup.bash
if [ -f /opt/base_ws/install/setup.bash ]; then
  source /opt/base_ws/install/setup.bash
fi
if [ -f /opt/overlay_ws/install/setup.bash ]; then
  source /opt/overlay_ws/install/setup.bash
fi
exec "$@"
