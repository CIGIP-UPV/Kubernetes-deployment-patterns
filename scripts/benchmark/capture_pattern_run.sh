#!/usr/bin/env bash
# =============================================================================
# capture_pattern_run.sh — Cold-start T_ready capture for the paper
# =============================================================================
# Wraps a clean Helm install of one of the canonical patterns and captures:
#
#   - T_ready_per_pod      (PodScheduled → Ready, from .status.conditions)
#   - T_ready_total_system (first PodScheduled → last Ready of all release pods)
#   - kubectl get events (full timeline of the install)
#   - kubectl describe pod (each release pod, snapshotted when Ready)
#   - kubectl top pod (steady-state resource usage)
#   - du -sh /opt/overlay (extracted overlay size on edge, when applicable)
#   - sudo k3s ctr images list (cached image sizes per node)
#
# Output:
#   results/<pattern>/<scenario>/{events.log, conditions.json, top.txt,
#                                 describe-<pod>.txt, image-sizes.txt,
#                                 summary.md}
#
# Usage:
#   scripts/benchmark/capture_pattern_run.sh <pattern> <scenario> [release] [namespace]
#
#   Examples:
#     # S1 cold-start of overlay-canonical (FPS=10)
#     scripts/benchmark/capture_pattern_run.sh overlay-canonical S1 \
#         over-pattern ros2exp
#
#     # Same pattern, S2 (FPS=20) — assumes pod has been kubectl-deleted to
#     # force restart so we can re-time everything cleanly.
#     scripts/benchmark/capture_pattern_run.sh overlay-canonical S2 \
#         over-pattern ros2exp
#
# Pre-requisites for a TRUE cold-start measurement (run on each node):
#
#     # edgenode01
#     sudo k3s ctr images rm gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes/ros2-base:latest
#     # worker1-kb2
#     sudo k3s ctr images rm gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes/ros2-overlay-pack:latest
#     # kb2
#     sudo k3s ctr images rm gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes/ros2-dashboard:latest
#
#     # Then helm uninstall + delete the overlay PVC, and helm install fresh.
#     helm uninstall <release> -n ros2exp
#     kubectl delete pvc -n ros2exp -l app.kubernetes.io/instance=<release>
#
# This script does NOT do the uninstall/reinstall — it only CAPTURES the
# resulting timeline once the pods are Ready. Run it AFTER you've triggered
# the deploy and the pods are stable.
# =============================================================================
set -euo pipefail

PATTERN="${1:-}"
SCENARIO="${2:-S1}"
RELEASE="${3:-over-pattern}"
NAMESPACE="${4:-ros2exp}"

if [ -z "${PATTERN}" ]; then
  echo "Usage: $0 <pattern> <scenario> [release=over-pattern] [namespace=ros2exp]"
  echo "  Patterns: monolithic | microservices | overlay-canonical | dynamic-canonical"
  echo "  Scenario: S1 (FPS=10) | S2 (FPS=20) | S3 (FPS=30)"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${PROJECT_ROOT}/results/${PATTERN}/${SCENARIO}"
mkdir -p "${OUT_DIR}"

echo "============================================================"
echo " Capturing run: pattern=${PATTERN}  scenario=${SCENARIO}"
echo " Release=${RELEASE}  Namespace=${NAMESPACE}"
echo " Output → ${OUT_DIR}"
echo "============================================================"

# Pods belonging to the release (Helm sets app.kubernetes.io/instance label).
PODS=$(kubectl -n "${NAMESPACE}" get pods \
  -l "app.kubernetes.io/instance=${RELEASE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [ -z "${PODS}" ]; then
  echo "  ERROR: no pods found with label app.kubernetes.io/instance=${RELEASE}"
  echo "  Tip: helm list -n ${NAMESPACE}"
  exit 2
fi

echo ""
echo "[1/6] Wait for all pods to reach Ready=True..."
for pod in ${PODS}; do
  echo "  - ${pod}: waiting up to 30 min..."
  kubectl -n "${NAMESPACE}" wait pod/"${pod}" \
    --for=condition=Ready --timeout=30m \
    || { echo "  TIMEOUT on ${pod} — capturing anyway"; }
done

# ── Conditions: T_ready per pod ────────────────────────────────────────────
echo ""
echo "[2/6] T_ready per pod (PodScheduled → Ready)"
COND_JSON="${OUT_DIR}/conditions.json"
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${RELEASE}" \
  -o jsonpath='{range .items[*]}{"--- "}{.metadata.name}{" ---\n"}{.status.conditions}{"\n"}{end}' \
  > "${COND_JSON}"

declare -a T_READY_VALUES
T_READY_TABLE="${OUT_DIR}/t_ready.csv"
echo "pod,podscheduled,ready,delta_s" > "${T_READY_TABLE}"

FIRST_SCHED_TS=""
LAST_READY_TS=""

for pod in ${PODS}; do
  s=$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}')
  r=$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
  if [ -n "${s}" ] && [ -n "${r}" ]; then
    se=$(date -d "${s}" +%s)
    re=$(date -d "${r}" +%s)
    d=$((re - se))
    printf '  %-65s  %s → %s  Δ=%ss\n' "${pod}" "${s}" "${r}" "${d}"
    echo "${pod},${s},${r},${d}" >> "${T_READY_TABLE}"
    T_READY_VALUES+=("${d}")
    if [ -z "${FIRST_SCHED_TS}" ] || [ "${se}" -lt "$(date -d "${FIRST_SCHED_TS}" +%s)" ]; then
      FIRST_SCHED_TS="${s}"
    fi
    if [ -z "${LAST_READY_TS}" ] || [ "${re}" -gt "$(date -d "${LAST_READY_TS}" +%s)" ]; then
      LAST_READY_TS="${r}"
    fi
  fi
done

T_READY_SYSTEM=""
if [ -n "${FIRST_SCHED_TS}" ] && [ -n "${LAST_READY_TS}" ]; then
  T_READY_SYSTEM=$(( $(date -d "${LAST_READY_TS}" +%s) - $(date -d "${FIRST_SCHED_TS}" +%s) ))
  echo ""
  echo "  T_ready_system = ${T_READY_SYSTEM} s   (${FIRST_SCHED_TS} → ${LAST_READY_TS})"
fi

# ── Events timeline ────────────────────────────────────────────────────────
echo ""
echo "[3/6] Capturing events timeline..."
kubectl -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' \
  > "${OUT_DIR}/events.log"
echo "  → ${OUT_DIR}/events.log ($(wc -l < "${OUT_DIR}/events.log") lines)"

# ── kubectl describe pod (per pod) ─────────────────────────────────────────
echo ""
echo "[4/6] kubectl describe pod (per pod)..."
for pod in ${PODS}; do
  kubectl -n "${NAMESPACE}" describe pod "${pod}" \
    > "${OUT_DIR}/describe-${pod}.txt"
done
echo "  → ${OUT_DIR}/describe-*.txt"

# ── kubectl top pod (steady state) ─────────────────────────────────────────
echo ""
echo "[5/6] kubectl top pod (steady state)..."
{
  echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl -n "${NAMESPACE}" top pod -l "app.kubernetes.io/instance=${RELEASE}"
} > "${OUT_DIR}/top.txt"
cat "${OUT_DIR}/top.txt"

# ── Overlay size on edge (only meaningful for overlay-canonical) ──────────
if [ "${PATTERN}" = "overlay-canonical" ]; then
  echo ""
  echo "[5b/6] Overlay extracted size on edge..."
  RUNTIME_POD=$(echo "${PODS}" | tr ' ' '\n' | grep -E '^.*-canonical-0$' | head -1)
  if [ -n "${RUNTIME_POD}" ]; then
    kubectl -n "${NAMESPACE}" exec "${RUNTIME_POD}" -c overlay-runtime \
      -- du -sh /opt/overlay /opt/overlay/python-deps /opt/overlay/huggingface_cache 2>/dev/null \
      | tee "${OUT_DIR}/overlay-size.txt" || \
      echo "  (could not exec into ${RUNTIME_POD})"
  fi
fi

# ── Summary markdown ───────────────────────────────────────────────────────
echo ""
echo "[6/6] Writing summary..."
SUMMARY="${OUT_DIR}/summary.md"
{
  echo "# ${PATTERN} — ${SCENARIO} run summary"
  echo ""
  echo "_Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
  echo ""
  echo "Release: \`${RELEASE}\`  ·  Namespace: \`${NAMESPACE}\`"
  echo ""
  echo "## T_ready"
  echo ""
  echo "| Pod | Δ (s) | PodScheduled | Ready |"
  echo "|---|---|---|---|"
  while IFS=, read -r p ps r d; do
    [ "${p}" = "pod" ] && continue
    echo "| \`${p}\` | ${d} | ${ps} | ${r} |"
  done < "${T_READY_TABLE}"
  echo ""
  echo "**T_ready_system** (first PodScheduled → last Ready) = **${T_READY_SYSTEM:-n/a} s**"
  echo ""
  echo "## Steady-state resource usage"
  echo ""
  echo '```'
  cat "${OUT_DIR}/top.txt"
  echo '```'
  echo ""
  echo "## Files in this run"
  echo ""
  ls -la "${OUT_DIR}" | awk 'NR>1 {print "- "$NF}' | grep -v '^- \.$\|^- \.\.$' || true
} > "${SUMMARY}"

echo ""
echo "============================================================"
echo " Done. Summary → ${SUMMARY}"
echo "============================================================"
echo ""
echo " Don't forget to ALSO capture from the dashboard (≥10 min runtime):"
echo "   - Screenshot of 'Métricas de Benchmark' card"
echo "   - T_inf (avg), f_FPS (pub/theor), T_e2e, J_inf"
echo "   - U_CPU (avg/max), U_GPU (avg/max), U_RAM (avg/max)"
echo " Save as: ${OUT_DIR}/dashboard.png"
