#!/usr/bin/env bash
set -e
source /opt/ros/${ROS_DISTRO}/setup.bash
if [ -f /opt/ros2_monolithic_ws/install/setup.bash ]; then
  source /opt/ros2_monolithic_ws/install/setup.bash
fi
exec "$@"
