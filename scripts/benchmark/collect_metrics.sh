#!/usr/bin/env bash
# =============================================================================
# collect_metrics.sh — Offline benchmark metrics for the paper
# =============================================================================
# Captures the metrics that DO NOT live in the dashboard (because they are
# build-time, deploy-time, or external-system metrics):
#
#   S_img      Image footprint                    (docker image inspect)
#   T_install  Cold installation time             (timer wrapper around helm)
#   T_sched    Scheduling latency                 (kubectl events parse)
#   L_net      Network latency edge↔cloud         (ping + iperf3)
#   C_cfg      Config churn                       (git diff --stat)
#   T_CI       CI pipeline time                   (gh actions API)
#
# Plus derived indicators when T_ready is supplied (read from dashboard):
#   eta_start  = 1 / (T_install + T_ready)
#   R_deploy   = T_install / T_ready
#
# Usage:
#   scripts/benchmark/collect_metrics.sh <pattern> [release-name] [namespace] [t_ready_sec]
#
#   Examples:
#     scripts/benchmark/collect_metrics.sh monolithic mono-pattern ros2exp
#     scripts/benchmark/collect_metrics.sh microservices mircor-pattern ros2exp 4.2
#
# Output: writes <pattern>.metrics.md and <pattern>.metrics.csv under
#         dist/metrics/ (created if missing).
#
# Notes:
#   - This script must run on a host with kubectl configured (e.g. kb2 server,
#     or your laptop with KUBECONFIG pointed at the cluster).
#   - docker inspect runs against the LOCAL docker daemon (where you build).
#     For images already pushed to the registry, use `crane manifest` instead.
#   - L_net requires iperf3 server running on one of the nodes.
# =============================================================================
set -o pipefail
# NOTE: NOT using `set -u` because empty arrays (e.g. T_SCHED_LINES when no pods
# found, or when run from a host without kubectl) trigger 'unbound variable'
# under the `for line in "${arr[@]}"` pattern. We do explicit checks instead.

PATTERN="${1:-}"
RELEASE="${2:-}"
NAMESPACE="${3:-ros2exp}"
T_READY="${4:-}"

if [ -z "${PATTERN}" ]; then
  echo "Usage: $0 <pattern> [release] [namespace] [t_ready_sec]"
  echo "Patterns: monolithic | microservices | overlay-workspaces | dynamic-loader | overlay-canonical | dynamic-canonical"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${PROJECT_ROOT}/dist/metrics"
mkdir -p "${OUT_DIR}"
MD="${OUT_DIR}/${PATTERN}.metrics.md"
CSV="${OUT_DIR}/${PATTERN}.metrics.csv"

REGISTRY="gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes"

# Pattern → list of images that compose it.
case "${PATTERN}" in
  monolithic)
    IMAGES=("ros2-monolithic" "ros2-dashboard")
    ;;
  microservices)
    IMAGES=("ros2-camera" "ros2-yolo" "ros2-llava" "ros2-voxtral" "ros2-dashboard")
    ;;
  overlay-workspaces)
    IMAGES=("ros2-overlay" "ros2-dashboard")
    ;;
  dynamic-loader)
    IMAGES=("ros2-monolithic" "ros2-dashboard")  # uses the monolithic base
    ;;
  overlay-canonical)
    IMAGES=("ros2-base" "ros2-overlay-pack" "ros2-dashboard")
    ;;
  dynamic-canonical)
    IMAGES=("ros2-component-host" "ros2-dashboard")
    ;;
  *)
    echo "Unknown pattern: ${PATTERN}"; exit 1
    ;;
esac

echo "============================================================"
echo " Collecting metrics for pattern: ${PATTERN}"
echo "============================================================"

# ── S_img: image footprint ──────────────────────────────────────────────────
echo ""
echo "[1/6] S_img — Image footprint (per image)"
S_IMG_TOTAL_BYTES=0
S_IMG_LINES=()
for img in "${IMAGES[@]}"; do
  full="${REGISTRY}/${img}:latest"
  sz=$(docker image inspect "${full}" --format '{{.Size}}' 2>/dev/null || echo "")
  if [ -z "${sz}" ]; then
    echo "  ${img}: NOT FOUND locally (skipped)"
    S_IMG_LINES+=("${img}|n/a|n/a")
    continue
  fi
  gb=$(awk -v s="${sz}" 'BEGIN{printf "%.2f", s/1024/1024/1024}')
  echo "  ${img}: ${gb} GB (${sz} bytes)"
  S_IMG_TOTAL_BYTES=$((S_IMG_TOTAL_BYTES + sz))
  S_IMG_LINES+=("${img}|${gb}|${sz}")
done
S_IMG_TOTAL_GB=$(awk -v s="${S_IMG_TOTAL_BYTES}" 'BEGIN{printf "%.2f", s/1024/1024/1024}')
echo "  TOTAL: ${S_IMG_TOTAL_GB} GB"

# ── T_sched: scheduling latency from kubectl events ─────────────────────────
echo ""
echo "[2/6] T_sched — Scheduling latency (Scheduled → Started)"
T_SCHED_LINES=()
T_SCHED_VALUES=()
if [ -n "${RELEASE}" ] && command -v kubectl >/dev/null 2>&1; then
  # First check kubectl can reach the cluster at all.
  if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    echo "  kubectl not connected to cluster, or namespace '${NAMESPACE}' does not exist"
    echo "  (Try: kubectl get nodes — should list edgenode01, kb2, worker1-kb2)"
  else
    # Find pods belonging to the release. Try the standard Helm label first;
    # if empty, list all pods so the user can see what label/release name to use.
    pods=$(kubectl -n "${NAMESPACE}" get pods \
      -l app.kubernetes.io/instance="${RELEASE}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    if [ -z "${pods}" ]; then
      echo "  No pods found for release '${RELEASE}' in ns ${NAMESPACE}"
      echo "  Existing releases (helm list -n ${NAMESPACE}):"
      helm list -n "${NAMESPACE}" 2>/dev/null | awk 'NR>1 {print "    "$1"  ("$NF")"}' || \
        echo "    (helm not installed or no releases found)"
      echo "  Existing pods + their app.kubernetes.io/instance label:"
      kubectl -n "${NAMESPACE}" get pods -o custom-columns=NAME:.metadata.name,RELEASE:.metadata.labels.'app\.kubernetes\.io/instance' 2>/dev/null || true
    else
      for pod in ${pods}; do
        sched_ts=$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
          -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}' 2>/dev/null || echo "")
        ready_ts=$(kubectl -n "${NAMESPACE}" get pod "${pod}" \
          -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || echo "")
        if [ -n "${sched_ts}" ] && [ -n "${ready_ts}" ]; then
          s=$(date -d "${sched_ts}" +%s 2>/dev/null || echo 0)
          r=$(date -d "${ready_ts}" +%s 2>/dev/null || echo 0)
          diff=$((r - s))
          echo "  ${pod}: ${diff} s  (scheduled ${sched_ts} → started ${ready_ts})"
          T_SCHED_LINES+=("${pod}|${diff}|${sched_ts}|${ready_ts}")
          T_SCHED_VALUES+=("${diff}")
        else
          echo "  ${pod}: timestamps missing (may not be ready yet)"
        fi
      done
    fi
  fi
else
  echo "  kubectl not available or no release specified — skipping"
fi
T_SCHED_AVG=""
if [ ${#T_SCHED_VALUES[@]} -gt 0 ]; then
  T_SCHED_AVG=$(printf '%s\n' "${T_SCHED_VALUES[@]}" \
    | awk '{s+=$1;n++} END{if(n) printf "%.1f", s/n}')
fi

# ── L_net: ping between known nodes ─────────────────────────────────────────
echo ""
echo "[3/6] L_net — Network latency"
L_NET_LINES=()
for target_pair in "kb2:158.42.104.15" "edgenode01:158.42.104.206" "worker1-kb2:158.42.104.103"; do
  name="${target_pair%%:*}"
  ip="${target_pair##*:}"
  if rtt=$(ping -c 3 -W 2 "${ip}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}'); then
    if [ -n "${rtt}" ]; then
      echo "  ${name} (${ip}): ${rtt} ms avg"
      L_NET_LINES+=("${name}|${ip}|${rtt}")
    else
      echo "  ${name} (${ip}): no reply"
      L_NET_LINES+=("${name}|${ip}|unreachable")
    fi
  else
    echo "  ${name} (${ip}): ping failed"
    L_NET_LINES+=("${name}|${ip}|unreachable")
  fi
done
echo "  (For bandwidth, run 'iperf3 -c <node>' separately and add manually.)"

# ── C_cfg: config churn since last tag ──────────────────────────────────────
echo ""
echo "[4/6] C_cfg — Config churn (Helm values + templates) since last git tag"
C_CFG_LINES=""
C_CFG_FILES=0
C_CFG_INSERT=0
C_CFG_DELETE=0
if command -v git >/dev/null 2>&1 && [ -d "${PROJECT_ROOT}/.git" ]; then
  cd "${PROJECT_ROOT}"
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [ -n "${last_tag}" ]; then
    # Map pattern → chart path
    case "${PATTERN}" in
      monolithic)        chart_dir="Patterns/monolithic/helm" ;;
      microservices)     chart_dir="Patterns/microservices/helm/ros2-microservices" ;;
      overlay-workspaces) chart_dir="Patterns/overlay-workspaces/helm/ros2-overlay" ;;
      dynamic-loader)    chart_dir="Patterns/dynamic-loader/helm/dynamic-loader" ;;
      overlay-canonical) chart_dir="Patterns/overlay-canonical/helm/ros2-overlay-canonical" ;;
      dynamic-canonical) chart_dir="Patterns/dynamic-canonical/helm/ros2-dynamic-canonical" ;;
    esac
    diff_stat=$(git diff --stat "${last_tag}" -- "${chart_dir}" 2>/dev/null | tail -1 || echo "")
    if [ -n "${diff_stat}" ]; then
      C_CFG_LINES="${diff_stat}"
      C_CFG_FILES=$(echo "${diff_stat}" | awk '{print $1}')
      C_CFG_INSERT=$(echo "${diff_stat}" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
      C_CFG_DELETE=$(echo "${diff_stat}" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' || echo 0)
      echo "  Since ${last_tag}: ${diff_stat}"
    else
      echo "  No churn since ${last_tag} for ${chart_dir}"
    fi
  else
    echo "  No git tags — skipping churn"
  fi
else
  echo "  Not a git repo or git missing"
fi

# ── T_CI: GitHub Actions runtime ─────────────────────────────────────────────
echo ""
echo "[5/6] T_CI — Last successful CI workflow runtime"
T_CI_VALUE=""
if command -v gh >/dev/null 2>&1; then
  # Last completed run of build-and-publish.yaml; report duration in seconds.
  ci_data=$(gh run list \
    --workflow=build-and-publish.yaml \
    --limit=5 --json status,conclusion,startedAt,updatedAt \
    --jq '.[] | select(.status=="completed" and .conclusion=="success") | "\(.startedAt)|\(.updatedAt)"' \
    | head -1)
  if [ -n "${ci_data}" ]; then
    s=$(date -d "${ci_data%%|*}" +%s 2>/dev/null || echo 0)
    e=$(date -d "${ci_data##*|}" +%s 2>/dev/null || echo 0)
    T_CI_VALUE=$((e - s))
    echo "  Last successful run: ${T_CI_VALUE} s"
  else
    echo "  No successful CI runs found"
  fi
else
  echo "  gh CLI not installed — skipping (install with: brew install gh)"
fi

# ── Derived indicators ──────────────────────────────────────────────────────
echo ""
echo "[6/6] Derived indicators"
ETA_START=""
R_DEPLOY=""
if [ -n "${T_READY}" ] && [ -n "${T_SCHED_AVG}" ]; then
  # Use T_SCHED_AVG as a stand-in for T_install when no helm wrapper was used.
  ETA_START=$(awk -v t="${T_SCHED_AVG}" -v r="${T_READY}" 'BEGIN{printf "%.4f", 1.0/(t+r)}')
  R_DEPLOY=$(awk -v t="${T_SCHED_AVG}" -v r="${T_READY}" 'BEGIN{if(r>0) printf "%.2f", t/r}')
  echo "  η_start = 1/(T_install + T_ready) = ${ETA_START} (using T_sched as proxy for T_install)"
  echo "  R_deploy = T_install / T_ready = ${R_DEPLOY}"
else
  echo "  Provide T_ready (4th arg) for derived indicators"
fi

# ── Write Markdown report ────────────────────────────────────────────────────
{
  echo "# Benchmark Metrics — ${PATTERN}"
  echo ""
  echo "_Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) by collect_metrics.sh_"
  echo ""
  echo "Release: \`${RELEASE:-(not provided)}\`  ·  Namespace: \`${NAMESPACE}\`"
  echo ""
  echo "## S_img — Image footprint"
  echo ""
  echo "| Image | Size (GB) | Bytes |"
  echo "|-------|-----------|-------|"
  for line in "${S_IMG_LINES[@]}"; do
    IFS='|' read -r img gb sz <<< "${line}"
    echo "| ${img} | ${gb} | ${sz} |"
  done
  echo "| **TOTAL** | **${S_IMG_TOTAL_GB}** | **${S_IMG_TOTAL_BYTES}** |"
  echo ""
  echo "## T_sched — Scheduling latency (per pod)"
  echo ""
  echo "| Pod | Δ (s) | Scheduled | Started |"
  echo "|-----|-------|-----------|---------|"
  for line in "${T_SCHED_LINES[@]}"; do
    IFS='|' read -r pod d s e <<< "${line}"
    echo "| ${pod} | ${d} | ${s} | ${e} |"
  done
  if [ -n "${T_SCHED_AVG}" ]; then
    echo ""
    echo "**Average T_sched: ${T_SCHED_AVG} s**"
  fi
  echo ""
  echo "## L_net — Round-trip latency"
  echo ""
  echo "| Node | IP | RTT avg (ms) |"
  echo "|------|------|--------------|"
  for line in "${L_NET_LINES[@]}"; do
    IFS='|' read -r name ip rtt <<< "${line}"
    echo "| ${name} | ${ip} | ${rtt} |"
  done
  echo ""
  echo "_Bandwidth (iperf3) must be measured manually._"
  echo ""
  echo "## C_cfg — Config churn"
  echo ""
  echo "${C_CFG_LINES:-_(no diff or no tags)_}"
  echo ""
  echo "## T_CI — Last successful build"
  echo ""
  echo "Duration: \`${T_CI_VALUE:-n/a}\` seconds"
  echo ""
  echo "## Derived"
  echo ""
  echo "| Indicator | Value |"
  echo "|-----------|-------|"
  echo "| T_ready (from dashboard) | ${T_READY:-n/a} s |"
  echo "| η_start | ${ETA_START:-n/a} |"
  echo "| R_deploy | ${R_DEPLOY:-n/a} |"
} > "${MD}"

# ── Write CSV (single row, easy to concat across patterns) ──────────────────
{
  if [ ! -s "${CSV}" ]; then
    echo "pattern,timestamp,s_img_total_gb,t_sched_avg_s,l_net_kb2_ms,l_net_edge_ms,c_cfg_files,t_ci_s,t_ready_s,eta_start,r_deploy"
  fi
  l_net_kb2=$(printf '%s\n' "${L_NET_LINES[@]}" | grep -E '^kb2\|' | awk -F '|' '{print $3}' | head -1)
  l_net_edge=$(printf '%s\n' "${L_NET_LINES[@]}" | grep -E '^edgenode01\|' | awk -F '|' '{print $3}' | head -1)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${PATTERN}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${S_IMG_TOTAL_GB}" \
    "${T_SCHED_AVG:-}" \
    "${l_net_kb2:-}" \
    "${l_net_edge:-}" \
    "${C_CFG_FILES}" \
    "${T_CI_VALUE:-}" \
    "${T_READY:-}" \
    "${ETA_START:-}" \
    "${R_DEPLOY:-}"
} >> "${CSV}"

echo ""
echo "============================================================"
echo " Done."
echo " Markdown: ${MD}"
echo " CSV:      ${CSV}"
echo "============================================================"
