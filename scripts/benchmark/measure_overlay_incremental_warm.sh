#!/usr/bin/env bash
# =============================================================================
# measure_overlay_incremental_warm.sh — Mide el T_install del patrón overlay
# en el escenario "incremental warm": el clúster ya tiene overlay desplegado,
# la PVC del tarball se preserva (no se borra el namespace), y el runtime
# StatefulSet se re-rolla para forzar el ciclo completo de redescarga del
# overlay desde nginx + boot del pod + carga de los 4 modelos en GPU.
#
# Esto corresponde al caso de uso real de overlay (republicar un modelo nuevo
# sobre la base inmutable), opuesto al "cold-cold" de la campaña (purga total
# de imágenes y namespace) y al "warm" de la campaña (que también borra la PVC
# del overlay porque el nuclear_cleanup_namespace destruye todo el namespace).
#
# Pre-requisitos:
#   - overlay-pattern instalado y Running en ros2exp (kubectl get pods -n ros2exp).
#   - PROJECT_ROOT con la estructura habitual del repo.
#
# Uso:
#   bash scripts/benchmark/measure_overlay_incremental_warm.sh
#
# Variables de entorno (opcionales):
#   N                Default 5. Número de ciclos de "incremental warm" a medir.
#   PAUSE_BETWEEN    Default 60. Segundos de pausa entre ciclos.
#   NAMESPACE        Default ros2exp.
#   RELEASE          Default overlay-pattern.
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:-ros2exp}"
RELEASE="${RELEASE:-overlay-pattern}"
N="${N:-5}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-60}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${PROJECT_ROOT}/results/overlay_incremental_warm/${TS}"
mkdir -p "${OUTDIR}"
LOG="${OUTDIR}/measurements.csv"
echo "cycle,t_zero,t_fin,t_install_e2e_s,pods_running" > "${LOG}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# ── Pre-flight: comprobar que overlay está desplegado ──
log "Pre-flight: comprobando que overlay-pattern está en ${NAMESPACE}..."
if ! helm list -n "${NAMESPACE}" -q | grep -q "^${RELEASE}$"; then
  log "ERROR: release '${RELEASE}' no encontrado en ${NAMESPACE}."
  log "  Instala overlay primero:"
  log "    helm upgrade --install ${RELEASE} Patterns/overlay-canonical/helm/ros2-overlay-canonical/ -n ${NAMESPACE}"
  log "  y espera a que llegue a Running antes de relanzar este script."
  exit 1
fi

# Localizar el StatefulSet del runtime (no el del dashboard)
RUNTIME_STS=$(kubectl get statefulset -n "${NAMESPACE}" -o name 2>/dev/null \
              | grep -v dashboard | head -1)
if [ -z "${RUNTIME_STS}" ]; then
  log "ERROR: no encuentro el StatefulSet de runtime en ${NAMESPACE}."
  kubectl get statefulset -n "${NAMESPACE}"
  exit 1
fi
log "Runtime StatefulSet detectado: ${RUNTIME_STS}"

# Confirmar que el pod runtime está Ready ANTES de empezar
RUNTIME_POD=$(kubectl get pods -n "${NAMESPACE}" \
              -o jsonpath='{.items[?(@.metadata.ownerReferences[0].kind=="StatefulSet")].metadata.name}' \
              | tr ' ' '\n' | grep -v dashboard | head -1)
log "Runtime pod inicial: ${RUNTIME_POD}"
log "Esperando a que el runtime pod esté Ready (timeout 10m) antes de empezar..."
kubectl wait --for=condition=Ready "pod/${RUNTIME_POD}" -n "${NAMESPACE}" --timeout=600s
log "OK: runtime listo. Empezamos los ${N} ciclos de incremental warm."

# Save the PVC info just for the record
PVC_NAME=$(kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | head -1)
log "PVC del overlay: ${PVC_NAME} (preservada durante toda la medición)"

# ── Bucle de N ciclos: rollout restart + medición ──
for i in $(seq 1 "${N}"); do
  log ""
  log "──────────────────────────────────────────────"
  log " Ciclo incremental warm ${i} / ${N}"
  log "──────────────────────────────────────────────"

  T_ZERO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  T_ZERO_EPOCH=$(date -u +%s)

  # Trigger: rollout restart del StatefulSet del runtime.
  # Esto provoca que k8s borre el pod actual y arranque uno nuevo. La PVC del
  # overlay (cloud-side) se preserva. El emptyDir del runtime sí se destruye,
  # así que el init container 'overlay-sync' se ejecuta de nuevo: probe del
  # tarball local NO existe (emptyDir vacío) → curl desde nginx → tar extract.
  log "  [1/3] kubectl rollout restart ${RUNTIME_STS}..."
  kubectl rollout restart "${RUNTIME_STS}" -n "${NAMESPACE}"

  # rollout status espera a que el StatefulSet termine de rotar pods.
  log "  [2/3] Esperando rollout status (timeout 20m)..."
  kubectl rollout status "${RUNTIME_STS}" -n "${NAMESPACE}" --timeout=1200s

  # Doble check explícito de Ready en el pod runtime nuevo.
  RUNTIME_POD=$(kubectl get pods -n "${NAMESPACE}" \
                -o jsonpath='{.items[?(@.metadata.ownerReferences[0].kind=="StatefulSet")].metadata.name}' \
                | tr ' ' '\n' | grep -v dashboard | head -1)
  log "  [3/3] Confirmando Ready en ${RUNTIME_POD}..."
  kubectl wait --for=condition=Ready "pod/${RUNTIME_POD}" -n "${NAMESPACE}" --timeout=1200s

  T_FIN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  T_FIN_EPOCH=$(date -u +%s)
  T_INSTALL=$((T_FIN_EPOCH - T_ZERO_EPOCH))

  PODS_RUNNING=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
                 | awk '$3=="Running"' | wc -l)

  echo "${i},${T_ZERO},${T_FIN},${T_INSTALL},${PODS_RUNNING}" >> "${LOG}"
  log "  RESULTADO ciclo ${i}: T_install = ${T_INSTALL} s  (pods Running: ${PODS_RUNNING})"

  if [ "${i}" -lt "${N}" ]; then
    log "  Pausa de ${PAUSE_BETWEEN} s antes del siguiente ciclo..."
    sleep "${PAUSE_BETWEEN}"
  fi
done

# ── Resumen estadístico ──
log ""
log "═════════════════════════════════════════════════════"
log " Mediciones completas (${N} ciclos)"
log "═════════════════════════════════════════════════════"
log " Fichero: ${LOG}"
echo ""
column -t -s ',' "${LOG}"
echo ""

python3 << PYEOF
import csv, statistics
with open("${LOG}") as f:
    rows = list(csv.DictReader(f))
vals = [int(r['t_install_e2e_s']) for r in rows]
print(f"  n      = {len(vals)}")
print(f"  mean   = {statistics.mean(vals):.1f} s")
if len(vals) > 1:
    print(f"  stdev  = {statistics.stdev(vals):.1f} s")
print(f"  min    = {min(vals)} s")
print(f"  max    = {max(vals)} s")
PYEOF
