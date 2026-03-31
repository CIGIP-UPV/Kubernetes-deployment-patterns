#!/bin/bash
set -e

source /opt/ros/humble/setup.bash

# Merge ConfigMap HTML (/dashboard-cm) + pre-bundled libs into /dashboard
# ConfigMap is readOnly, so we copy everything into a writable directory
mkdir -p /dashboard/lib
if [ -d /dashboard-cm ]; then
  cp /dashboard-cm/* /dashboard/ 2>/dev/null || true
  echo "[dashboard] HTML copied from ConfigMap"
fi
if [ -d /opt/dashboard-lib ]; then
  cp /opt/dashboard-lib/* /dashboard/lib/ 2>/dev/null || true
  echo "[dashboard] Static libs (roslib.js) ready"
fi

echo "[dashboard] Starting rosbridge WebSocket on port 9090..."
ros2 launch rosbridge_server rosbridge_websocket_launch.xml \
    port:=9090 \
    address:=0.0.0.0 &
BRIDGE_PID=$!

echo "[dashboard] Starting HTTP server on port 8080..."
cd /dashboard && python3 -m http.server 8080 &
HTTP_PID=$!

echo "[dashboard] Dashboard ready:"
echo "  Web UI:    http://$(hostname -I | awk '{print $1}'):8080"
echo "  WebSocket: ws://$(hostname -I | awk '{print $1}'):9090"

# Wait for either process to exit
wait -n ${BRIDGE_PID} ${HTTP_PID}
exit 1
