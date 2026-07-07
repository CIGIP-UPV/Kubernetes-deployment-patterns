#!/usr/bin/env bash
# =============================================================================
# measure_overlay_once.sh — Mide una réplica de overlay desplegado
#                          manualmente desde Rancher.
# =============================================================================
# overlay no se puede instalar por `helm install --wait` desde CLI
# (su Job pre-install excede el deadline del hook). Pero desde Rancher UI sí,
# porque respeta la anotación catalog.cattle.io/timeout. Este script asume
# que TÚ ya has desplegado overlay-pattern por Rancher y está Ready, y se
# encarga del resto con la MISMA metodología que run_full_campaign.sh:
# warmup + muestreo + guardado en el formato de comparison.
#
# Uso:
#   bash scripts/benchmark/measure_overlay_once.sh <num_replica> [hora_inicio_utc]
#
#   <num_replica>      1..5 — identifica la réplica.
#   [hora_inicio_utc]  (opcional) hora UTC en que pulsaste "Install" en Rancher,
#                      formato 2026-05-20T08:15:00Z. Si la das, se calcula
#                      T_install_e2e. Si no, el script intenta deducir T_zero
#                      del creationTimestamp del primer recurso de la release.
#
# Ejemplo:
#   # 1. En Rancher: Install overlay, release=overlay-pattern, ns=ros2exp
#   # 2. Cuando esté Ready, anota la hora y lanza:
#   bash scripts/benchmark/measure_overlay_once.sh 1 2026-05-20T08:15:00Z
#   # 3. Cuando termine, desinstala en Rancher y repite con replica 2, 3, 4, 5.
#
# Variables de entorno (opcionales):
#   NAMESPACE        Default ros2exp
#   RELEASE          Default overlay-pattern
#   WARMUP_SECONDS   Default 600 (10 min) — igual que la meta-campaña.
#   SAMPLE_SECONDS   Default 180 (3 min)  — igual que la meta-campaña.
#   ROSBRIDGE_URL    Default ws://158.42.104.15:31407
#   OUT_BASE         Default results/_campaigns/overlay-manual
# =============================================================================
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Uso: $0 <num_replica> [hora_inicio_utc]"
  echo "Ej:  $0 1 2026-05-20T08:15:00Z"
  exit 1
fi

REPLICA="$1"
T_ZERO_ARG="${2:-}"

# Validar que REPLICA es un número (1..N). Si no, abortar con mensaje claro
# en vez de romper más adelante con "value too great for base".
if ! [[ "${REPLICA}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: el primer argumento debe ser el NÚMERO de réplica (1..5), no '${REPLICA}'."
  echo "Uso: $0 <num_replica> [hora_inicio_utc]"
  echo "Ej:  $0 1 2026-05-20T08:15:00Z"
  exit 1
fi

NAMESPACE="${NAMESPACE:-ros2exp}"
RELEASE="${RELEASE:-overlay-pattern}"
WARMUP_SECONDS="${WARMUP_SECONDS:-600}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-180}"
ROSBRIDGE_URL="${ROSBRIDGE_URL:-ws://158.42.104.15:31407}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_BASE="${OUT_BASE:-${PROJECT_ROOT}/results/_campaigns/overlay-manual}"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${OUT_BASE}/${TS}-rep${REPLICA}"
mkdir -p "${RUN_DIR}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

log "════════════════════════════════════════════════════════════"
log " Medición manual de overlay — réplica ${REPLICA}"
log " Namespace : ${NAMESPACE}"
log " Release   : ${RELEASE}"
log " Salida    : ${RUN_DIR}"
log "════════════════════════════════════════════════════════════"

# ── 1. Verificar que overlay está desplegado y Ready ────────────────────────
# IMPORTANTE: overlay tiene un Job efímero de pre-install
# (overlay-pattern-overlay-installer-XXXXX) que copia ~17 GB a la PVC ANTES de
# que la aplicación real arranque. Ese Job comparte la label
# app.kubernetes.io/instance, así que NO podemos esperar "cualquier pod" con
# esa label: matcharía el installer y daríamos por listo algo que aún no lo
# está. Esperamos específicamente a los pods del StatefulSet de la app:
# el runtime (overlay-pattern-0) y el dashboard (overlay-pattern-dashboard-0,
# que expone el rosbridge que necesita el sampler).
RUNTIME_POD="${RELEASE}-0"
DASHBOARD_POD="${RELEASE}-dashboard-0"

log "[1/5] Verificando que ${RELEASE} está completamente desplegado en ${NAMESPACE}..."
kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" > "${RUN_DIR}/pods_at_start.txt" 2>&1
cat "${RUN_DIR}/pods_at_start.txt"

# Si solo existe el pod installer (la app real aún no se ha creado), abortar
# con un mensaje claro: hay que esperar a que termine el pre-install.
if ! kubectl get pod "${DASHBOARD_POD}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  log "  ERROR: el pod del dashboard (${DASHBOARD_POD}) todavía no existe."
  log "  Probablemente overlay sigue en fase de pre-install (Job overlay-installer"
  log "  copiando los ~17 GB a la PVC). Espera en Rancher a que TODOS los pods"
  log "  estén verdes (overlay-pattern-0, overlay-pattern-dashboard-0,"
  log "  overlay-pattern-overlay-server-...) y vuelve a lanzar el script."
  log "  Esta carpeta (${RUN_DIR}) puede borrarse."
  exit 1
fi

# Esperar a que runtime + dashboard estén Ready (hasta 45 min por si justo
# acabas de pulsar Install y el pre-install todavía está en marcha).
log "  Esperando a que ${RUNTIME_POD} y ${DASHBOARD_POD} estén Ready (timeout 45m)..."
kubectl wait "pod/${RUNTIME_POD}"   -n "${NAMESPACE}" --for=condition=Ready --timeout=45m 2>&1 | tee -a "${RUN_DIR}/wait.log" || \
  log "  WARNING: ${RUNTIME_POD} no llegó a Ready en 45m."
kubectl wait "pod/${DASHBOARD_POD}" -n "${NAMESPACE}" --for=condition=Ready --timeout=45m 2>&1 | tee -a "${RUN_DIR}/wait.log" || \
  log "  WARNING: ${DASHBOARD_POD} no llegó a Ready en 45m."

# ── 2. T_install / T_ready ──────────────────────────────────────────────────
log "[2/5] Calculando T_install y T_ready_system..."

# T_ready_system: ventana desde el primer PodScheduled al último Ready
# (segundos), EXCLUYENDO el pod installer (efímero, no es parte de la app).
kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" \
  -o json 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); d['items']=[p for p in d['items'] if 'installer' not in p['metadata']['name']]; json.dump(d,sys.stdout)" \
  > "${RUN_DIR}/pods.json"

python3 - "${RUN_DIR}/pods.json" "${T_ZERO_ARG}" > "${RUN_DIR}/timing.txt" <<'PYEOF'
import json, sys, datetime

pods_path = sys.argv[1]
t_zero_arg = sys.argv[2] if len(sys.argv) > 2 else ""

def parse(ts):
    if not ts:
        return None
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)

with open(pods_path) as f:
    data = json.load(f)

scheduled = []
ready = []
created = []
for item in data.get("items", []):
    meta = item.get("metadata", {})
    if meta.get("creationTimestamp"):
        created.append(parse(meta["creationTimestamp"]))
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == "PodScheduled" and c.get("lastTransitionTime"):
            scheduled.append(parse(c["lastTransitionTime"]))
        if c.get("type") == "Ready" and c.get("status") == "True" and c.get("lastTransitionTime"):
            ready.append(parse(c["lastTransitionTime"]))

t_ready_system = ""
if scheduled and ready:
    t_ready_system = int((max(ready) - min(scheduled)).total_seconds())

# T_install_e2e: si el usuario dio hora de inicio (cuando pulsó Install en
# Rancher), usamos esa como T_zero; si no, usamos el primer creationTimestamp.
t_zero = parse(t_zero_arg) if t_zero_arg else (min(created) if created else None)
t_install = ""
if t_zero and ready:
    t_install = int((max(ready) - t_zero).total_seconds())

t_zero_str = t_zero.strftime("%Y-%m-%dT%H:%M:%SZ") if t_zero else ""
t_fin_str = max(ready).strftime("%Y-%m-%dT%H:%M:%SZ") if ready else ""

print(f"T_ZERO={t_zero_str}")
print(f"T_FIN={t_fin_str}")
print(f"T_INSTALL={t_install}")
print(f"T_READY_SYSTEM={t_ready_system}")
PYEOF

cat "${RUN_DIR}/timing.txt"
# Cargar las variables calculadas
# shellcheck disable=SC1090
source "${RUN_DIR}/timing.txt"
echo "${T_ZERO}" > "${RUN_DIR}/T_zero.txt"
echo "${T_FIN}"  > "${RUN_DIR}/T_fin.txt"

# ── 3. Warmup ─────────────────────────────────────────────────────────────
log "[3/5] Warm-up: durmiendo ${WARMUP_SECONDS}s para estabilizar LLaVA + métricas..."
sleep "${WARMUP_SECONDS}"

# ── 4. Muestreo del dashboard ───────────────────────────────────────────────
log "[4/5] Muestreando dashboard ${SAMPLE_SECONDS}s vía rosbridge..."
python3 "${PROJECT_ROOT}/scripts/benchmark/sample_dashboard_metrics.py" \
        --rosbridge-url "${ROSBRIDGE_URL}" \
        --duration "${SAMPLE_SECONDS}" \
        --output "${RUN_DIR}/dashboard_samples.csv" \
        2>&1 | tee -a "${RUN_DIR}/sampler.log"

# ── 5. Fila comparison-style ────────────────────────────────────────────────
log "[5/5] Escribiendo fila de métricas..."
AGG=",,,,,,"
STATUS="no_samples"
if [ -f "${RUN_DIR}/dashboard_aggregate.csv" ]; then
  AGG=$(tail -1 "${RUN_DIR}/dashboard_aggregate.csv" | tr -d '\r')
  STATUS="ok"
fi

# S_img total para overlay (base + overlay-pack), si están en containerd local.
S_IMG=""

COMP="${RUN_DIR}/comparison.csv"
echo "pattern,t_zero,t_fin,t_install_e2e_s,t_ready_system_s,s_img_total_gb,t_inf_avg_ms,f_fps_pub,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,u_ram_avg_pct,run_dir,status,notes" > "${COMP}"
echo "overlay,${T_ZERO},${T_FIN},${T_INSTALL},${T_READY_SYSTEM},${S_IMG},${AGG},${RUN_DIR},${STATUS},rep${REPLICA}" >> "${COMP}"

log "════════════════════════════════════════════════════════════"
log " Réplica ${REPLICA} completada."
log " T_install_e2e = ${T_INSTALL}s   T_ready_system = ${T_READY_SYSTEM}s"
log " Métricas: ${AGG}"
log " Carpeta : ${RUN_DIR}"
log "════════════════════════════════════════════════════════════"
log ""
log " SIGUIENTE: desinstala overlay-pattern en Rancher, espera a que los pods"
log "            desaparezcan, y lanza la siguiente réplica:"
log "   bash scripts/benchmark/measure_overlay_once.sh $((REPLICA + 1)) <hora_inicio_utc>"
column -t -s ',' "${COMP}"
