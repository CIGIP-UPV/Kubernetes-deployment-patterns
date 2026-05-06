#!/usr/bin/env bash
# =============================================================================
# run_full_campaign.sh — automated, unattended benchmark of the four patterns
# =============================================================================
# Runs the four deployment patterns sequentially with **identical methodology**
# so the runtime metrics are comparable apples-to-apples (same warmup, same
# sample window, same LLaVA trigger interval).
#
# Per pattern the script does:
#   1. Uninstall any previous Helm release with the same name.
#   2. Delete leftover PVCs (only relevant for overlay-canonical).
#   3. (Optional) SSH into the nodes and purge the containerd images so the
#      run is a true cold-cold (env COLD_COLD=true; needs SSH keys).
#   4. helm install with values that pin the camera and LLaVA settings.
#   5. kubectl wait ... --for=condition=Ready (records T_install_e2e).
#   6. Sleep WARMUP_SECONDS so LLaVA fires at least once and metrics stabilise.
#   7. Capture kubectl artefacts (conditions, events, top, describe) via
#      capture_pattern_run.sh.
#   8. Sample rosbridge topics for SAMPLE_SECONDS via
#      sample_dashboard_metrics.py and dump CSV.
#   9. (dynamic-canonical only) Capture C-7 unload/load latency via
#      capture_dynamic_load_unload.sh.
#  10. Aggregate via collect_metrics.sh.
#  11. (Default) leave the deployment running so a human can inspect; set
#      KEEP_DEPLOYMENT=false to uninstall after each pattern.
#
# At the end the script writes a comparison.csv with one row per pattern.
#
# Usage:
#   nohup bash scripts/benchmark/run_full_campaign.sh > campaign.log 2>&1 &
#
# Environment variables (all optional):
#   PATTERNS              Space-separated subset, default "monolithic microservices overlay-canonical dynamic-canonical"
#   NAMESPACE             Default ros2exp
#   WARMUP_SECONDS        Default 600 (10 min). Wait after Ready before sampling.
#   SAMPLE_SECONDS        Default 180 (3 min). Sample window for dashboard metrics.
#   ROSBRIDGE_URL         Default ws://158.42.104.15:31407 (NodePort of dashboard service on kb2).
#   CAMERA_DEVICE         Default /dev/video1
#   COLD_COLD             Default false. If true, SSH into nodes and purge images before each install.
#                         Requires SSH keys for: anakin@edgenode01, administrador@worker1-kb2, administrador@kb2
#   KEEP_DEPLOYMENT       Default true. Leave each helm release running between patterns. Set false to uninstall.
#   ABORT_FILE            Default /tmp/STOP_CAMPAIGN. Touch this file between patterns to abort gracefully.
#   RESULTS_BASE          Default results/_campaigns
#   REGISTRY              Default gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
#   IMAGE_TAG             Default latest
#
# To monitor progress:
#   tail -f campaign.log
#
# To stop after the current pattern finishes:
#   touch /tmp/STOP_CAMPAIGN
#
# Pre-requisites:
#   - kubectl access to the cluster (KUBECONFIG set or default ~/.kube/config)
#   - helm 3.x
#   - python3 with `roslibpy` installed (pip install roslibpy)
#     OR: docker available (we'll fall back to a one-shot container)
#   - SSH keys to the nodes only if COLD_COLD=true
# =============================================================================
set -uo pipefail

# Don't `set -e` — we want to continue even if one pattern fails.

# ── Defaults ────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-ros2exp}"
PATTERNS="${PATTERNS:-monolithic microservices overlay-canonical dynamic-canonical}"
WARMUP_SECONDS="${WARMUP_SECONDS:-600}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-180}"
ROSBRIDGE_URL="${ROSBRIDGE_URL:-ws://158.42.104.15:31407}"
CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video1}"
COLD_COLD="${COLD_COLD:-false}"
KEEP_DEPLOYMENT="${KEEP_DEPLOYMENT:-true}"
ABORT_FILE="${ABORT_FILE:-/tmp/STOP_CAMPAIGN}"
RESULTS_BASE="${RESULTS_BASE:-results/_campaigns}"
REGISTRY="${REGISTRY:-gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
CAMPAIGN_DIR="${PROJECT_ROOT}/${RESULTS_BASE}/${TS}"
mkdir -p "${CAMPAIGN_DIR}"

CAMPAIGN_LOG="${CAMPAIGN_DIR}/campaign.log"
COMPARISON_CSV="${CAMPAIGN_DIR}/comparison.csv"
COMPARISON_MD="${CAMPAIGN_DIR}/comparison.md"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "${msg}"
  echo "${msg}" >> "${CAMPAIGN_LOG}"
}

log "============================================================"
log " Campaign starting (id=${TS})"
log " Patterns      : ${PATTERNS}"
log " Namespace     : ${NAMESPACE}"
log " Warmup        : ${WARMUP_SECONDS} s"
log " Sample window : ${SAMPLE_SECONDS} s"
log " Cold-cold     : ${COLD_COLD}"
log " Output        : ${CAMPAIGN_DIR}"
log "============================================================"

# Initialize comparison CSV header.
echo "pattern,t_zero,t_fin,t_install_e2e_s,t_ready_system_s,s_img_total_gb,t_inf_avg_ms,f_fps_pub,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,u_ram_avg_pct,run_dir,status,notes" > "${COMPARISON_CSV}"

# ── Helper: optionally purge containerd images on each node ─────────────────
purge_node_images() {
  if [ "${COLD_COLD}" != "true" ]; then
    return 0
  fi
  local pattern=$1
  log "  [cold-cold] Purging containerd images on cluster nodes..."

  case "${pattern}" in
    monolithic|microservices|overlay-canonical|dynamic-canonical)
      # Each pattern uses a different set of images. We purge ALL pattern-related
      # images to play it safe — pulls happen on next install only for the ones
      # that the chart actually uses.
      for host_user in anakin@edgenode01 administrador@worker1-kb2 administrador@kb2; do
        log "    purging on ${host_user}..."
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${host_user}" \
          "sudo k3s ctr images list -q | grep -E 'patrones-kubernetes/(ros2-base|ros2-overlay-pack|ros2-component-host|ros2-monolithic|ros2-camera|ros2-yolo|ros2-llava|ros2-voxtral|ros2-dashboard)' | xargs -r sudo k3s ctr images rm; sudo k3s crictl rmi --prune" \
          >> "${CAMPAIGN_LOG}" 2>&1 || \
          log "    WARNING: ssh to ${host_user} failed (skipping)"
      done
      ;;
  esac
}

# ── Helper: short release name for each pattern ────────────────────────────
# Kubernetes label values cap at 63 chars. Helm-generated Job names follow
# the format "<release>-<chart>-<suffix>", so a long release name overflows
# the limit (e.g. "overlay-canonical-pattern-ros2-overlay-canonical-overlay-
# installer" = 66 chars). We use the same short release names as the
# Rancher deployments to stay safely under the cap.
release_name_for() {
  case "$1" in
    monolithic)         echo "monolithic-pattern" ;;
    microservices)      echo "microservices-pattern" ;;
    overlay-canonical)  echo "overlay-pattern" ;;
    dynamic-canonical)  echo "dynamic-pattern" ;;
    *)                  echo "$1-pattern" ;;
  esac
}

# ── Helper: install a pattern via helm ──────────────────────────────────────
install_pattern() {
  local pattern=$1
  local release=$2

  # Helm's default --timeout for pre-install/post-install hooks is 5 min,
  # which is too short for overlay-canonical (26 GB image pull + 17 GB
  # cp to PVC during the pre-install Job) and dynamic-canonical (32 GB
  # pull + bootstrap Job loading 4 plugins). We bump to 45m to match
  # the catalog.cattle.io/timeout already declared in those charts'
  # Chart.yaml annotations.
  local HELM_TIMEOUT="${HELM_TIMEOUT:-45m}"

  case "${pattern}" in
    monolithic)
      helm install "${release}" "${PROJECT_ROOT}/Patterns/monolithic/helm" \
        -n "${NAMESPACE}" --create-namespace \
        --timeout "${HELM_TIMEOUT}" --wait \
        --set image.tag="${IMAGE_TAG}" \
        --set camera.device="${CAMERA_DEVICE}"
      ;;
    microservices)
      helm install "${release}" "${PROJECT_ROOT}/Patterns/microservices/helm/ros2-microservices" \
        -n "${NAMESPACE}" --create-namespace \
        --timeout "${HELM_TIMEOUT}" --wait \
        --set image.tag="${IMAGE_TAG}" \
        --set camera.device="${CAMERA_DEVICE}"
      ;;
    overlay-canonical)
      helm install "${release}" "${PROJECT_ROOT}/Patterns/overlay-canonical/helm/ros2-overlay-canonical" \
        -n "${NAMESPACE}" --create-namespace \
        --timeout "${HELM_TIMEOUT}" --wait \
        --set images.base.tag="${IMAGE_TAG}" \
        --set images.overlayPack.tag="${IMAGE_TAG}" \
        --set camera.device="${CAMERA_DEVICE}"
      ;;
    dynamic-canonical)
      helm install "${release}" "${PROJECT_ROOT}/Patterns/dynamic-canonical/helm/ros2-dynamic-canonical" \
        -n "${NAMESPACE}" --create-namespace \
        --timeout "${HELM_TIMEOUT}" --wait \
        --set image.tag="${IMAGE_TAG}" \
        --set camera.device="${CAMERA_DEVICE}"
      ;;
    *)
      log "  ERROR: unknown pattern '${pattern}'"; return 1
      ;;
  esac
}

# ── Helper: uninstall a pattern (best-effort) ────────────────────────────────
uninstall_pattern() {
  local release=$1
  helm uninstall "${release}" -n "${NAMESPACE}" 2>>"${CAMPAIGN_LOG}" || true
  kubectl delete pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${release}" \
    --ignore-not-found=true 2>>"${CAMPAIGN_LOG}" || true
}

# ── Main loop ────────────────────────────────────────────────────────────────
for pattern in ${PATTERNS}; do
  if [ -e "${ABORT_FILE}" ]; then
    log "Abort file detected (${ABORT_FILE}); stopping before pattern ${pattern}."
    rm -f "${ABORT_FILE}"
    break
  fi

  log ""
  log "═════════════════════════════════════════════════════════════"
  log " Pattern: ${pattern}"
  log "═════════════════════════════════════════════════════════════"

  RELEASE="$(release_name_for "${pattern}")"
  RUN_DIR="${CAMPAIGN_DIR}/${pattern}"
  mkdir -p "${RUN_DIR}"
  STATUS="ok"
  NOTES=""

  # 1. Cleanup
  log "  [1/9] Uninstall any leftover release..."
  uninstall_pattern "${RELEASE}"
  sleep 8

  # 2. Optional cold-cold image purge
  log "  [2/9] (Cold-cold? ${COLD_COLD}) Purging images..."
  purge_node_images "${pattern}"

  # 3. T_zero
  T_ZERO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "${T_ZERO}" > "${RUN_DIR}/T_zero.txt"
  T_ZERO_EPOCH=$(date -u -d "${T_ZERO}" +%s 2>/dev/null || gdate -u -d "${T_ZERO}" +%s)
  log "  [3/9] T_zero=${T_ZERO}"

  # 4. helm install
  log "  [4/9] helm install ${RELEASE} (${pattern})..."
  if ! install_pattern "${pattern}" "${RELEASE}" >> "${CAMPAIGN_LOG}" 2>&1; then
    STATUS="install_failed"
    NOTES="helm install returned non-zero"
    log "    INSTALL FAILED — continuing with next pattern"
    echo "${pattern},${T_ZERO},,,,,,,,,,,${RUN_DIR},${STATUS},${NOTES}" >> "${COMPARISON_CSV}"
    continue
  fi

  # 5. Wait Ready
  log "  [5/9] kubectl wait Ready (timeout 45m)..."
  if ! kubectl wait pod -n "${NAMESPACE}" \
        -l "app.kubernetes.io/instance=${RELEASE}" \
        --for=condition=Ready --timeout=45m >> "${CAMPAIGN_LOG}" 2>&1; then
    STATUS="ready_timeout"
    NOTES="kubectl wait timed out at 45m"
    log "    READY TIMEOUT — capturing what we have"
  fi
  T_FIN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "${T_FIN}" > "${RUN_DIR}/T_fin.txt"
  T_FIN_EPOCH=$(date -u -d "${T_FIN}" +%s 2>/dev/null || gdate -u -d "${T_FIN}" +%s)
  T_INSTALL=$((T_FIN_EPOCH - T_ZERO_EPOCH))
  log "  [5/9] T_fin=${T_FIN}  T_install_e2e=${T_INSTALL}s"

  # 6. Warm-up
  log "  [6/9] Warm-up: sleeping ${WARMUP_SECONDS}s..."
  sleep "${WARMUP_SECONDS}"

  # 7. Capture kubectl artefacts via existing script (auto-S1 scenario name).
  log "  [7/9] Capturing kubectl artefacts via capture_pattern_run.sh..."
  bash "${PROJECT_ROOT}/scripts/benchmark/capture_pattern_run.sh" \
       "${pattern}" "auto-${TS}" "${RELEASE}" "${NAMESPACE}" \
       >> "${CAMPAIGN_LOG}" 2>&1 || NOTES="${NOTES};capture_pattern_run failed"
  # Copy whatever the script produced into our campaign dir.
  cp -r "${PROJECT_ROOT}/results/${pattern}/auto-${TS}/"* "${RUN_DIR}/" 2>/dev/null || true

  # 8. Sample dashboard metrics via rosbridge.
  log "  [8/9] Sampling dashboard metrics for ${SAMPLE_SECONDS}s..."
  python3 "${PROJECT_ROOT}/scripts/benchmark/sample_dashboard_metrics.py" \
          --rosbridge-url "${ROSBRIDGE_URL}" \
          --duration "${SAMPLE_SECONDS}" \
          --output "${RUN_DIR}/dashboard_samples.csv" \
          >> "${CAMPAIGN_LOG}" 2>&1 || NOTES="${NOTES};dashboard_sampler failed"

  # 8.b (dynamic only) C-7 capture
  if [ "${pattern}" = "dynamic-canonical" ]; then
    log "  [8b/9] Capturing C-7 load/unload latency..."
    bash "${PROJECT_ROOT}/scripts/benchmark/capture_dynamic_load_unload.sh" \
         "${RELEASE}" "${NAMESPACE}" \
         >> "${CAMPAIGN_LOG}" 2>&1 || NOTES="${NOTES};C-7 capture failed"
  fi

  # 9. collect_metrics.sh aggregation
  log "  [9/9] collect_metrics.sh ${pattern}..."
  bash "${PROJECT_ROOT}/scripts/benchmark/collect_metrics.sh" \
       "${pattern}" "${RELEASE}" "${NAMESPACE}" "${T_INSTALL}" \
       >> "${CAMPAIGN_LOG}" 2>&1 || NOTES="${NOTES};collect_metrics failed"

  # Read aggregated metrics from the dashboard samples to populate the
  # comparison CSV row. The python sampler writes a one-row aggregate file
  # next to the raw samples called dashboard_aggregate.csv.
  AGG_FILE="${RUN_DIR}/dashboard_aggregate.csv"
  if [ -f "${AGG_FILE}" ]; then
    # CSV header: t_inf_avg_ms,f_fps_avg,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,u_ram_avg_pct
    AGG=$(tail -1 "${AGG_FILE}")
  else
    AGG=",,,,,,"
  fi

  # S_img total: parse from collect_metrics output if available
  S_IMG=""
  if [ -f "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" ]; then
    S_IMG=$(tail -1 "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" | awk -F',' '{print $3}')
  fi

  # T_ready_system: parse first PodScheduled → last Ready from t_ready.csv
  T_READY_SYSTEM=""
  if [ -f "${RUN_DIR}/t_ready.csv" ]; then
    T_READY_SYSTEM=$(awk -F',' 'NR>1 {if($4>max) max=$4} END {print max}' "${RUN_DIR}/t_ready.csv")
  fi

  echo "${pattern},${T_ZERO},${T_FIN},${T_INSTALL},${T_READY_SYSTEM},${S_IMG},${AGG},${RUN_DIR},${STATUS},${NOTES}" \
    >> "${COMPARISON_CSV}"

  # Optional uninstall
  if [ "${KEEP_DEPLOYMENT}" != "true" ]; then
    log "  cleanup: helm uninstall ${RELEASE}..."
    uninstall_pattern "${RELEASE}"
  fi

  log "  DONE: ${pattern}  T_install=${T_INSTALL}s  status=${STATUS}"
done

# ── Final summary ───────────────────────────────────────────────────────────
log ""
log "═════════════════════════════════════════════════════════════"
log " Campaign complete"
log "═════════════════════════════════════════════════════════════"
log " Comparison CSV: ${COMPARISON_CSV}"
log " Per-pattern results: ${CAMPAIGN_DIR}/<pattern>/"
log " Full log: ${CAMPAIGN_LOG}"

# Pretty-print the comparison
{
  echo "# Campaign comparison — ${TS}"
  echo ""
  echo "| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
  while IFS=, read -r pat tz tf tinst tready simg tinf fps te2e jinf ucpu ugpu uram rd st nt; do
    [ "${pat}" = "pattern" ] && continue
    echo "| ${pat} | ${tinst} | ${tready} | ${simg} | ${tinf} | ${fps} | ${te2e} | ${jinf} | ${ucpu} | ${ugpu} | ${uram} | ${st} |"
  done < "${COMPARISON_CSV}"
} > "${COMPARISON_MD}"

log " Markdown summary: ${COMPARISON_MD}"
log ""
log " To inspect: cat ${COMPARISON_MD}"
