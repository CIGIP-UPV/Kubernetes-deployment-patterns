#!/bin/bash
set -e

source /opt/ros/humble/setup.bash

# ── Resolve CycloneDDS peer DNS to IPs ──
# CycloneDDS only resolves peer addresses ONCE at startup.
# If DNS hasn't propagated yet, discovery silently fails.
# We resolve hostnames → IPs in the XML before launching.
if [ -f /etc/cyclonedds/cyclonedds.xml ]; then
  echo "[dashboard] Resolving CycloneDDS peer addresses to IPs..."
  cp /etc/cyclonedds/cyclonedds.xml /tmp/cyclonedds-resolved.xml

  # Extract all Peer Address hostnames and resolve them
  grep -oP 'Address="\K[^"]+' /tmp/cyclonedds-resolved.xml | while read -r PEER; do
    # Skip if it's already an IP
    if echo "$PEER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "  $PEER (already IP)"
      continue
    fi
    # Try to resolve up to 10 times (30s total)
    RESOLVED=""
    for i in $(seq 1 10); do
      RESOLVED=$(getent hosts "$PEER" 2>/dev/null | awk '{print $1}' | head -1)
      if [ -n "$RESOLVED" ]; then
        break
      fi
      echo "  [attempt $i/10] Cannot resolve $PEER, waiting 3s..."
      sleep 3
    done
    if [ -n "$RESOLVED" ]; then
      echo "  $PEER -> $RESOLVED"
      sed -i "s|Address=\"$PEER\"|Address=\"$RESOLVED\"|g" /tmp/cyclonedds-resolved.xml
    else
      echo "  WARNING: Could not resolve $PEER after 10 attempts"
    fi
  done

  export CYCLONEDDS_URI="file:///tmp/cyclonedds-resolved.xml"
  echo "[dashboard] CycloneDDS using resolved config: $CYCLONEDDS_URI"
fi

# ── Merge ConfigMap HTML + pre-bundled libs ──
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
