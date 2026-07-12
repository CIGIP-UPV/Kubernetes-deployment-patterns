#!/usr/bin/env bash
# Hot swap your model at runtime through the orchestrator sidecar (no pod
# restart). The orchestrator listens inside the runtime pod; we reach it with
# kubectl exec, so nothing needs to be exposed to the LAN.
set -euo pipefail
NS="${NS:-ros2exp}"
POD="${POD:-dynamic-pattern-0}"
EXEC="kubectl exec -n ${NS} ${POD} -c orchestrator --"

echo "── loaded components before:"
${EXEC} curl -s http://localhost:5000/list; echo

echo "── unload your model:"
${EXEC} curl -s --max-time 90 -X POST http://localhost:5000/unload \
  -H "Content-Type: application/json" -d '{"module":"yolo"}'; echo

echo "── load it again (with parameters):"
${EXEC} curl -s --max-time 300 -X POST http://localhost:5000/load \
  -H "Content-Type: application/json" \
  -d '{"module":"yolo","parameters":{"synthetic_inference_ms":20.0,"publish_metrics":true}}'; echo

echo "── loaded components after:"
${EXEC} curl -s http://localhost:5000/list; echo
