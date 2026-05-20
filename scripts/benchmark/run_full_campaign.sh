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
# Cloud node for overlay-canonical's pre-install Job, PVC and nginx
# overlay-server. Default kb2; set to worker1-kb2 if kb2 is short on disk
# (the overlay-pack image is ~26 GB and the PVC is ~30 GB, peak combined
# usage during the install is ~70 GB).
CLOUD_NODE="${CLOUD_NODE:-kb2}"
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
log " Cloud node    : ${CLOUD_NODE} (overlay-canonical Job + PVC + nginx)"
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
      # IMPORTANTE: overlay-canonical se instala SIN --wait, a propósito.
      # Con --wait, helm espera a que TODOS los pods estén Ready, incluido
      # overlay-pattern-0 en edgenode01, que tiene que bajar el tarball de
      # 17 GB del nginx server y descomprimirlo en el Jetson. Eso supera los
      # 45 min del timeout y helm mata la release entera (context deadline
      # exceeded). Sin --wait, helm devuelve en cuanto el hook pre-install
      # (installer Job) termina y se crean los recursos — igual que hace
      # Rancher de forma asíncrona. La espera real la hace el paso [5/9]
      # con kubectl wait y un timeout amplio (OVERLAY_READY_TIMEOUT).
      helm install "${release}" "${PROJECT_ROOT}/Patterns/overlay-canonical/helm/ros2-overlay-canonical" \
        -n "${NAMESPACE}" --create-namespace \
        --timeout "${HELM_TIMEOUT}" \
        --set images.base.tag="${IMAGE_TAG}" \
        --set images.overlayPack.tag="${IMAGE_TAG}" \
        --set nodes.cloud.name="${CLOUD_NODE}" \
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

# ── Helper: uninstall a pattern (best-effort, but aggressive) ────────────────
# El uninstall original era demasiado pasivo: si helm uninstall fallaba o solo
# borraba el release pero dejaba pods huérfanos (porque la release estaba en
# status=failed con recursos a medias), los ciclos siguientes se chocaban con
# "release already exists" al instalar. Ahora forzamos también el borrado
# de pods + PVCs + ConfigMaps + Secrets etiquetados por instancia, y esperamos
# a que el namespace quede limpio antes de devolver el control.
uninstall_pattern() {
  local release=$1
  helm uninstall "${release}" -n "${NAMESPACE}" --wait --timeout 5m 2>>"${CAMPAIGN_LOG}" || true
  # Fuerza el borrado de cualquier recurso que helm uninstall haya dejado
  # huérfano. --force --grace-period=0 evita esperar a que los pods
  # terminen gracilmente cuando ya están en estado roto.
  kubectl delete all,pvc,configmap,secret -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${release}" \
    --ignore-not-found=true --force --grace-period=0 \
    2>>"${CAMPAIGN_LOG}" || true
  # Por si el chart no etiqueta todo con app.kubernetes.io/instance, intentamos
  # también por prefijo de nombre (típico para PVCs de StatefulSet).
  kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | \
    grep -E "/${release}-" | \
    xargs -r kubectl delete -n "${NAMESPACE}" --ignore-not-found=true \
      --force --grace-period=0 2>>"${CAMPAIGN_LOG}" || true
}

# ── Helper: verificar que el namespace está limpio antes de install ──────────
# Si quedan pods de una release anterior (por un uninstall previo a medias),
# el helm install fallará. Esperamos hasta 60s a que el namespace se vacíe.
wait_namespace_empty_for_release() {
  local release=$1
  local max_wait=60
  local waited=0
  while [ "${waited}" -lt "${max_wait}" ]; do
    local count
    count=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${release}" --no-headers 2>/dev/null | wc -l)
    if [ "${count}" -eq 0 ]; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "    WARNING: tras ${max_wait}s aún quedan pods de ${release} en ${NAMESPACE}"
  kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${release}" >> "${CAMPAIGN_LOG}" 2>&1 || true
  return 1
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

  # 1. Cleanup (uninstall + wait until namespace is empty of this release's pods)
  log "  [1/9] Uninstall any leftover release..."
  uninstall_pattern "${RELEASE}"
  wait_namespace_empty_for_release "${RELEASE}"

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
    log "    INSTALL FAILED — cleaning up before next pattern"
    # CRÍTICO: limpiar lo que el install fallido haya dejado a medias antes
    # de saltar al siguiente patrón. Sin esto, el ciclo siguiente se choca
    # con recursos huérfanos.
    uninstall_pattern "${RELEASE}"
    wait_namespace_empty_for_release "${RELEASE}"
    echo "${pattern},${T_ZERO},,,,,,,,,,,${RUN_DIR},${STATUS},${NOTES}" >> "${COMPARISON_CSV}"
    continue
  fi

  # 5. Wait Ready
  # overlay-canonical necesita más tiempo: como se instala sin --wait, este
  # es el único punto donde esperamos a que el runtime pod baje y descomprima
  # el tarball de 17 GB en el edge. Le damos 90m. El resto, 45m.
  READY_TIMEOUT="45m"
  if [ "${pattern}" = "overlay-canonical" ]; then
    READY_TIMEOUT="${OVERLAY_READY_TIMEOUT:-90m}"
    # Al instalar sin --wait, los pods del StatefulSet tardan unos segundos en
    # aparecer. Esperamos a que exista al menos un pod (no-installer) antes de
    # llamar a kubectl wait, que si no fallaría con "no matching resources".
    log "  [5/9a] Esperando a que aparezcan los pods de ${RELEASE}..."
    appeared=0
    for _ in $(seq 1 24); do   # hasta 2 min (24 × 5s)
      n=$(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" \
            --no-headers 2>/dev/null | grep -v installer | wc -l)
      if [ "${n}" -ge 1 ]; then appeared=1; break; fi
      sleep 5
    done
    [ "${appeared}" -eq 0 ] && log "    WARNING: no aparecieron pods de ${RELEASE} en 2 min"
  fi
  log "  [5/9] kubectl wait Ready (timeout ${READY_TIMEOUT})..."
  if ! kubectl wait pod -n "${NAMESPACE}" \
        -l "app.kubernetes.io/instance=${RELEASE}" \
        --for=condition=Ready --timeout="${READY_TIMEOUT}" >> "${CAMPAIGN_LOG}" 2>&1; then
    STATUS="ready_timeout"
    NOTES="kubectl wait timed out at ${READY_TIMEOUT}"
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
    # Python's csv.writer writes CRLF line endings by default (RFC 4180); strip
    # the trailing \r so it doesn't poison the concatenated comparison row.
    AGG=$(tail -1 "${AGG_FILE}" | tr -d '\r')
  else
    AGG=",,,,,,"
  fi

  # S_img total: parse from collect_metrics output if available
  S_IMG=""
  if [ -f "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" ]; then
    S_IMG=$(tail -1 "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" | awk -F',' '{print $3}' | tr -d '\r')
  fi

  # T_ready_system: parse first PodScheduled → last Ready from t_ready.csv
  T_READY_SYSTEM=""
  if [ -f "${RUN_DIR}/t_ready.csv" ]; then
    T_READY_SYSTEM=$(awk -F',' 'NR>1 {if($4>max) max=$4} END {print max}' "${RUN_DIR}/t_ready.csv" | tr -d '\r')
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
