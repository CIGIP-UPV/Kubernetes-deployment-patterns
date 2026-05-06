#!/usr/bin/env bash
# =============================================================================
# capture_dynamic_load_unload.sh — C-7 metric for dynamic-canonical
# =============================================================================
# Measures load/unload latency per module for the dynamic-canonical pattern.
# This is the diferenciador del paper: dynamic supports hot-swap of components
# (no need to restart the pod), and we want to quantify how fast.
#
# Calls the orchestrator FastAPI inside the runtime pod via `kubectl exec`,
# so it works without exposing the API to the LAN.
#
# Output: results/dynamic-canonical/load-unload/
#   - load_unload_per_module.csv  (one row per module: name, load_s, unload_s)
#   - summary.md
#
# Usage:
#   scripts/benchmark/capture_dynamic_load_unload.sh \
#       [release=dynamic-pattern] [namespace=ros2exp]
#
# Pre-requisites:
#   - dynamic-canonical chart deployed (orchestrator + component-host running)
#   - Bootstrap Job has already loaded `camera` (or load it manually first)
# =============================================================================
set -euo pipefail

RELEASE="${1:-dynamic-pattern}"
NAMESPACE="${2:-ros2exp}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${PROJECT_ROOT}/results/dynamic-canonical/load-unload"
mkdir -p "${OUT_DIR}"

CSV="${OUT_DIR}/load_unload_per_module.csv"
SUMMARY="${OUT_DIR}/summary.md"

RUNTIME_POD="${RELEASE}-ros2-dynamic-canonical-0"
ORCH_URL="http://localhost:5000"

# Find the orchestrator container by name (it's a sidecar in the runtime pod).
EXEC="kubectl exec -n ${NAMESPACE} ${RUNTIME_POD} -c orchestrator --"

# Module catalog with the parameters the orchestrator expects.
# (This mirrors what bootstrap-job.yaml passes — keep in sync.)
declare -A MODULE_PARAMS=(
  [yolo]='{"module":"yolo","parameters":{"model_path":"/opt/models/yolov8n.pt","conf":0.25,"filter_classes":"0,56,60","publish_debug_image":"true","publish_metrics":"true"}}'
  [llava]='{"module":"llava","parameters":{"hf_cache_dir":"/opt/huggingface_cache","load4bit":true,"max_new_tokens":150,"trigger_on_yolo":true,"yolo_trigger_interval_s":30.0}}'
  [voxtral]='{"module":"voxtral","parameters":{"hf_cache_dir":"/opt/huggingface_cache","audio_mode":false}}'
)

MODULES_ORDER=(yolo llava voxtral)

echo "============================================================"
echo " Capturing dynamic-canonical C-7: load/unload latency"
echo " Pod=${RUNTIME_POD}  Namespace=${NAMESPACE}"
echo " Output → ${OUT_DIR}"
echo "============================================================"

echo "module,load_s,unload_s,load_status,unload_status" > "${CSV}"

for module in "${MODULES_ORDER[@]}"; do
  params="${MODULE_PARAMS[$module]}"
  echo ""
  echo "─── Module: ${module} ───"

  # ── LOAD ──────────────────────────────────────────────────────────
  start_ts=$(date +%s.%N)
  load_resp=$(${EXEC} curl -sX POST "${ORCH_URL}/load" \
    -H "Content-Type: application/json" \
    -d "${params}" 2>&1) || true
  end_ts=$(date +%s.%N)
  load_s=$(awk -v s="${start_ts}" -v e="${end_ts}" 'BEGIN{printf "%.2f", e-s}')

  if echo "${load_resp}" | grep -q '"status":"loaded"'; then
    load_status="OK"
    echo "  load:   ${load_s} s   ${load_resp}"
  else
    load_status="FAIL"
    echo "  load:   ${load_s} s   FAILED: ${load_resp}"
  fi

  # Settle a couple of seconds so the node fully initializes before unload
  sleep 3

  # ── UNLOAD ────────────────────────────────────────────────────────
  start_ts=$(date +%s.%N)
  unload_resp=$(${EXEC} curl -sX POST "${ORCH_URL}/unload" \
    -H "Content-Type: application/json" \
    -d "{\"module\":\"${module}\"}" 2>&1) || true
  end_ts=$(date +%s.%N)
  unload_s=$(awk -v s="${start_ts}" -v e="${end_ts}" 'BEGIN{printf "%.2f", e-s}')

  if echo "${unload_resp}" | grep -q '"status":"unloaded"'; then
    unload_status="OK"
    echo "  unload: ${unload_s} s   ${unload_resp}"
  else
    unload_status="FAIL"
    echo "  unload: ${unload_s} s   FAILED: ${unload_resp}"
  fi

  echo "${module},${load_s},${unload_s},${load_status},${unload_status}" >> "${CSV}"
  sleep 2
done

# ── Write summary ──────────────────────────────────────────────────
{
  echo "# dynamic-canonical — C-7 load/unload latency"
  echo ""
  echo "_Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
  echo ""
  echo "Release: \`${RELEASE}\`  ·  Namespace: \`${NAMESPACE}\`"
  echo ""
  echo "## Per-module results"
  echo ""
  echo "| Module | Load (s) | Unload (s) | Load status | Unload status |"
  echo "|--------|----------|------------|-------------|---------------|"
  while IFS=, read -r m l u ls us; do
    [ "${m}" = "module" ] && continue
    echo "| ${m} | ${l} | ${u} | ${ls} | ${us} |"
  done < "${CSV}"
  echo ""
  echo "## Comparison context"
  echo ""
  echo "These are the times the operator pays to **swap a single AI module**"
  echo "without restarting the pod. For comparison:"
  echo ""
  echo "| Pattern | Time to swap one model |"
  echo "|---------|------------------------|"
  echo "| monolithic | ~15-25 min (rebuild image + push + pull + boot) |"
  echo "| microservices | ~5-10 min (rebuild ONE microservice + push + pull) |"
  echo "| overlay-canonical | ~16 min cold-cold, ~2.5 min cold-ish (re-extract overlay) |"
  echo "| **dynamic-canonical** | **load_s + unload_s seconds** ⭐ |"
  echo ""
  echo "## Files in this run"
  echo ""
  ls -la "${OUT_DIR}" | awk 'NR>1 {print "- "$NF}' | grep -v '^- \.$\|^- \.\.$' || true
} > "${SUMMARY}"

echo ""
echo "============================================================"
echo " Done."
echo " CSV:     ${CSV}"
echo " Summary: ${SUMMARY}"
echo "============================================================"
