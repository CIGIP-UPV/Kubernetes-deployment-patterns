#!/usr/bin/env bash
# =============================================================================
# run_n_campaigns.sh — Lanza N campañas completas en serie, alternando regimen
# =============================================================================
# Pensado para dejarlo corriendo varios días con nohup y obtener múltiples
# repeticiones de las métricas de los 4 patrones (foto real + detección de
# outliers).
#
# Cada campaña interna llama a run_full_campaign.sh, que recorre los 4
# patrones (monolithic, microservices, overlay-canonical, dynamic-canonical)
# con metodología uniforme (10 min warmup + 3 min muestreo).
#
# Resultados:
#   results/_campaigns/<TIMESTAMP_1>/   ← ciclo 1
#   results/_campaigns/<TIMESTAMP_2>/   ← ciclo 2
#   ...
#   results/_campaigns/_summary_<TS>.csv   ← agregado de todos los ciclos
#
# Uso típico (en kb2, dejarlo corriendo):
#   cd ~/Kubernetes-deployment-patterns
#   git pull
#   nohup bash scripts/benchmark/run_n_campaigns.sh > meta_campaign.log 2>&1 &
#   tail -f meta_campaign.log
#
# Para abortar limpiamente entre ciclos:
#   touch /tmp/STOP_META_CAMPAIGN
#
# Variables de entorno (opcionales):
#   N_WARM         Default 3. Ciclos warm al principio (COLD_COLD=false).
#   N_COLD         Default 3. Ciclos cold-cold al final (COLD_COLD=true).
#   PAUSE_BETWEEN  Default 1800 (30 min). Pausa entre ciclos para que el
#                  cluster se asiente.
#   ABORT_FILE     Default /tmp/STOP_META_CAMPAIGN.
#
# Pre-requisitos:
#   - Para los ciclos COLD: claves SSH desde la máquina que lanza el script
#     hacia anakin@edgenode01, administrador@worker1-kb2, administrador@kb2.
#     Si no las tienes configuradas, deja N_COLD=0 y haz solo warm.
# =============================================================================
set -uo pipefail

N_WARM="${N_WARM:-3}"
N_COLD="${N_COLD:-3}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-1800}"
ABORT_FILE="${ABORT_FILE:-/tmp/STOP_META_CAMPAIGN}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
META_TS="$(date +%Y%m%d-%H%M%S)"
META_SUMMARY="${PROJECT_ROOT}/results/_campaigns/_summary_${META_TS}.csv"

mkdir -p "${PROJECT_ROOT}/results/_campaigns"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log "════════════════════════════════════════════════════════════"
log " Meta-campaña iniciada (id=${META_TS})"
log " Ciclos warm     : ${N_WARM}"
log " Ciclos cold-cold: ${N_COLD}"
log " Pausa entre     : ${PAUSE_BETWEEN}s"
log " Resumen final   : ${META_SUMMARY}"
log " Aborta tocando  : ${ABORT_FILE}"
log "════════════════════════════════════════════════════════════"

echo "cycle,regimen,campaign_dir,started_at,finished_at,duration_s" > "${META_SUMMARY}"

# ── Pre-flight: verificar que el secret regcred existe en ros2exp ───────────
# Sin este secret los pods se quedan en ImagePullBackOff durante 45 min antes
# de que helm install --wait dé timeout. Mejor abortar aquí con un mensaje
# accionable.
NAMESPACE_CHECK="${NAMESPACE:-ros2exp}"
if ! kubectl get namespace "${NAMESPACE_CHECK}" >/dev/null 2>&1; then
  log "Pre-flight: el namespace ${NAMESPACE_CHECK} no existe — se creará al hacer helm install."
  log "  Pero entonces tampoco existirá el secret regcred. Crea el namespace y el secret ANTES de lanzar la meta-campaña:"
  log "    kubectl create namespace ${NAMESPACE_CHECK}"
  log "    kubectl create secret docker-registry regcred ... -n ${NAMESPACE_CHECK}"
  exit 1
fi
if ! kubectl get secret regcred -n "${NAMESPACE_CHECK}" >/dev/null 2>&1; then
  log "Pre-flight FAILED: el secret 'regcred' no existe en el namespace ${NAMESPACE_CHECK}."
  log "  Los charts lo declaran en values.yaml (imagePullSecretName: regcred) y sin él los pods se quedan en ImagePullBackOff."
  log ""
  log "  Crea el secret antes de relanzar:"
  log "    kubectl create secret docker-registry regcred \\"
  log "      --docker-server=gitlab-cigip.alc.upv.es:5050 \\"
  log "      --docker-username='<USUARIO>' \\"
  log "      --docker-password='<TOKEN>' \\"
  log "      --docker-email='<EMAIL>' \\"
  log "      -n ${NAMESPACE_CHECK}"
  log ""
  log "  O, si tienes ~/.docker/config.json con login al registry:"
  log "    kubectl create secret generic regcred \\"
  log "      --from-file=.dockerconfigjson=\$HOME/.docker/config.json \\"
  log "      --type=kubernetes.io/dockerconfigjson \\"
  log "      -n ${NAMESPACE_CHECK}"
  exit 1
fi
log "Pre-flight OK: secret regcred presente en namespace ${NAMESPACE_CHECK}."

run_cycle() {
  local idx=$1
  local regimen=$2   # "warm" o "cold-cold"

  if [ -e "${ABORT_FILE}" ]; then
    log "Abort file detectado (${ABORT_FILE}); parando antes del ciclo ${idx}."
    rm -f "${ABORT_FILE}"
    return 99
  fi

  log ""
  log "────────────────────────────────────────────────────────────"
  log " Ciclo ${idx}  (regimen=${regimen})"
  log "────────────────────────────────────────────────────────────"

  local cold_flag="false"
  [ "${regimen}" = "cold-cold" ] && cold_flag="true"

  local started_at started_epoch finished_at finished_epoch duration
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_epoch="$(date -u +%s)"

  # Captura el TS interno que usará run_full_campaign.sh para saber qué
  # carpeta nos genera. Su script usa $(date +%Y%m%d-%H%M%S) en su línea 84.
  local cycle_ts
  cycle_ts="$(date +%Y%m%d-%H%M%S)"

  # Lanza el script interno con las variables de entorno necesarias.
  # KEEP_DEPLOYMENT=false para que entre ciclos no haya releases pegadas.
  COLD_COLD="${cold_flag}" \
  KEEP_DEPLOYMENT="false" \
  bash "${PROJECT_ROOT}/scripts/benchmark/run_full_campaign.sh" \
       >> "${PROJECT_ROOT}/results/_campaigns/_meta_${META_TS}.log" 2>&1

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_epoch="$(date -u +%s)"
  duration=$((finished_epoch - started_epoch))

  # La carpeta real puede no coincidir exactamente con cycle_ts si arrancó
  # un segundo más tarde; busca la más reciente bajo results/_campaigns/.
  local last_dir
  last_dir="$(ls -1dt "${PROJECT_ROOT}/results/_campaigns/"*/ 2>/dev/null | grep -v _summary | grep -v _meta | head -1)"

  echo "${idx},${regimen},${last_dir%/},${started_at},${finished_at},${duration}" >> "${META_SUMMARY}"
  log "Ciclo ${idx} terminado en ${duration}s. Carpeta: ${last_dir}"
}

cycle=0

# Bloque warm
for ((i=1; i<=N_WARM; i++)); do
  cycle=$((cycle+1))
  if ! run_cycle "${cycle}" "warm"; then
    log "Saliendo de la meta-campaña."
    break
  fi
  if [ "${cycle}" -lt "$((N_WARM + N_COLD))" ]; then
    log "Pausa de ${PAUSE_BETWEEN}s entre ciclos..."
    sleep "${PAUSE_BETWEEN}"
  fi
done

# Bloque cold-cold
for ((i=1; i<=N_COLD; i++)); do
  cycle=$((cycle+1))
  if ! run_cycle "${cycle}" "cold-cold"; then
    log "Saliendo de la meta-campaña."
    break
  fi
  if [ "${cycle}" -lt "$((N_WARM + N_COLD))" ]; then
    log "Pausa de ${PAUSE_BETWEEN}s entre ciclos..."
    sleep "${PAUSE_BETWEEN}"
  fi
done

log ""
log "════════════════════════════════════════════════════════════"
log " Meta-campaña completa"
log "════════════════════════════════════════════════════════════"
log " Resumen: ${META_SUMMARY}"
log ""
log " Para agregar todas las comparison.csv en un único CSV:"
log "   bash scripts/benchmark/aggregate_meta_campaign.sh ${META_SUMMARY}"
