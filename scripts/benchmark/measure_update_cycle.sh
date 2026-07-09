#!/usr/bin/env bash
# =============================================================================
# measure_update_cycle.sh — Comparación de actualización JUSTA entre patrones (R1.6)
# =============================================================================
# Mide la MISMA operación de actualización (nueva versión de los pesos YOLO)
# en cada patrón, desglosada por etapas, en lugar de comparar el hot-swap del
# dynamic contra un rebuild completo:
#
#   Etapas medidas (segundos; NA si no aplica al patrón):
#     t_publish   publicación del artefacto (push imagen / capa; opcional, ver BUILD_CMD)
#     t_rollout   orden de actualización → pods nuevos creados
#     t_ready     pods nuevos Ready (incluye pull/transfer al edge)
#     t_gap_max   interrupción de servicio: hueco máximo entre mensajes
#                 consecutivos de /benchmark/latency_ms durante la operación
#     t_rollback  vuelta a la versión anterior (misma vía)
#     status      OK / FAIL por etapa
#
#   Operación equivalente por patrón:
#     monolithic     helm upgrade --set image.tag=NEW        (re-ship 30 GB)
#     microservices  helm upgrade --set images.yolo.tag=NEW  (re-ship solo YOLO)
#     overlay        invalidar marker de la capa deps en el edge + rollout restart
#                    (re-transfer de la capa que contiene los pesos YOLO)
#     dynamic-loader POST /unload + /load de yolo con model_path nuevo
#                    (opcional: kubectl cp de los pesos primero = transfer)
#
# REQUISITOS:
#   - El patrón debe estar desplegado y Ready antes de invocar el script.
#   - Para monolithic/microservices: una imagen con tag NEW_TAG ya publicada en
#     el registry (el build+push se mide aparte con BUILD_CMD, porque depende
#     de la máquina de build, no del cluster).
#   - python3 + roslibpy en la máquina que ejecuta el script (sonda de gap).
#
# Uso:
#   NEW_TAG=update-test bash scripts/benchmark/measure_update_cycle.sh monolithic
#   NEW_TAG=update-test bash scripts/benchmark/measure_update_cycle.sh microservices
#   bash scripts/benchmark/measure_update_cycle.sh overlay
#   NEW_WEIGHTS_LOCAL=/path/yolov8n_v2.pt bash scripts/benchmark/measure_update_cycle.sh dynamic-loader
#
# Variables: NEW_TAG, OLD_TAG (def. latest), NAMESPACE (def. ros2exp),
#   ROSBRIDGE_URL, EDGE_PURGE_HOST, OVERLAY_HOSTPATH, NEW_WEIGHTS_LOCAL,
#   BUILD_CMD (comando opcional cuya duración se registra como t_publish),
#   DO_ROLLBACK (def. true), N_REPS (def. 1; repetir n>=3 para el paper).
# =============================================================================
set -uo pipefail

PATTERN="${1:?Uso: measure_update_cycle.sh <monolithic|microservices|overlay|dynamic-loader>}"
NAMESPACE="${NAMESPACE:-ros2exp}"
OLD_TAG="${OLD_TAG:-latest}"
NEW_TAG="${NEW_TAG:-}"
ROSBRIDGE_URL="${ROSBRIDGE_URL:-ws://158.42.104.15:31407}"
EDGE_PURGE_HOST="${EDGE_PURGE_HOST:-anakin@edgenode01.cigip.upv.es}"
OVERLAY_HOSTPATH="${OVERLAY_HOSTPATH:-/mnt/ssd/overlay-runtime}"
NEW_WEIGHTS_LOCAL="${NEW_WEIGHTS_LOCAL:-}"
DO_ROLLBACK="${DO_ROLLBACK:-true}"
N_REPS="${N_REPS:-1}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${PROJECT_ROOT}/results/update-cycle/${TS}"
mkdir -p "${OUT_DIR}"
CSV="${OUT_DIR}/update_${PATTERN}.csv"
GAP_CSV="${OUT_DIR}/service_gap_${PATTERN}.csv"

case "${PATTERN}" in
  monolithic)     RELEASE="monolithic-pattern";    CHART="${PROJECT_ROOT}/Patterns/monolithic/helm" ;;
  microservices)  RELEASE="microservices-pattern"; CHART="${PROJECT_ROOT}/Patterns/microservices/helm/ros2-microservices" ;;
  overlay)        RELEASE="overlay-pattern";       CHART="${PROJECT_ROOT}/Patterns/overlay/helm/ros2-overlay" ;;
  dynamic-loader) RELEASE="dynamic-pattern";       CHART="${PROJECT_ROOT}/Patterns/dynamic-loader/helm/dynamic-loader" ;;
  *) echo "Patron desconocido: ${PATTERN}"; exit 1 ;;
esac

now_s() { date +%s.%N; }
elapsed() { awk -v s="$1" -v e="$2" 'BEGIN{printf "%.2f", e-s}'; }
record() { echo "${PATTERN},$1,$2,$3,$4,\"$5\"" >> "${CSV}"; echo "  [${PATTERN}] $2: $3 s ($4) $5"; }

echo "pattern,rep,stage,seconds,status,notes" > "${CSV}"

# ── Sonda de interrupción de servicio ────────────────────────────────────────
# Suscribe /benchmark/latency_ms (una muestra por frame procesado por YOLO) via
# rosbridge y registra los timestamps; el gap máximo entre mensajes durante la
# ventana de actualización es la interrupción de servicio percibida.
start_gap_probe() {
  python3 - "$ROSBRIDGE_URL" "$GAP_CSV" <<'PYEOF' &
import sys, time, csv
from urllib.parse import urlparse
import roslibpy
url, out = sys.argv[1], sys.argv[2]
u = urlparse(url)
c = roslibpy.Ros(host=u.hostname, port=u.port or 9090)
c.run()
rows = []
def cb(msg):
    rows.append(time.time())
t = roslibpy.Topic(c, '/benchmark/latency_ms', 'std_msgs/Float32')
t.subscribe(cb)
try:
    while True:
        time.sleep(0.5)
except KeyboardInterrupt:
    pass
finally:
    with open(out, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['timestamp_unix'])
        for r in rows:
            w.writerow([f'{r:.3f}'])
    gaps = [b - a for a, b in zip(rows, rows[1:])]
    print(f'[probe] samples={len(rows)} gap_max={max(gaps):.2f}s' if gaps else '[probe] sin muestras')
    c.terminate()
PYEOF
  GAP_PID=$!
}

stop_gap_probe() {
  kill -INT "${GAP_PID}" 2>/dev/null || true
  wait "${GAP_PID}" 2>/dev/null || true
  # gap máximo a posteriori
  GAP_MAX=$(python3 - "$GAP_CSV" <<'PYEOF'
import sys, csv
try:
    ts = [float(r[0]) for r in list(csv.reader(open(sys.argv[1])))[1:]]
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    print(f"{max(gaps):.2f}" if gaps else "NA")
except Exception:
    print("NA")
PYEOF
)
}

wait_pods_ready() {
  kubectl wait pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" \
    --for=condition=Ready --timeout=60m >/dev/null 2>&1
}

for rep in $(seq 1 "${N_REPS}"); do
  echo "═══ ${PATTERN} — repetición ${rep}/${N_REPS} ═══"

  # 0) build/push opcional (se ejecuta en la máquina de build, no en el cluster)
  if [ -n "${BUILD_CMD:-}" ]; then
    t0=$(now_s); bash -c "${BUILD_CMD}" && st=OK || st=FAIL; t1=$(now_s)
    record "${rep}" t_publish "$(elapsed "$t0" "$t1")" "${st}" "BUILD_CMD"
  else
    record "${rep}" t_publish "NA" "SKIP" "artefacto pre-publicado (tag ${NEW_TAG:-n/a})"
  fi

  start_gap_probe
  sleep 10   # linea base de la sonda antes de la operación

  case "${PATTERN}" in
    monolithic|microservices)
      [ -z "${NEW_TAG}" ] && { echo "ERROR: NEW_TAG requerido para ${PATTERN}"; exit 1; }
      if [ "${PATTERN}" = "monolithic" ]; then SETARG="image.tag=${NEW_TAG}"; else SETARG="images.yolo.tag=${NEW_TAG}"; fi
      t0=$(now_s)
      helm upgrade "${RELEASE}" "${CHART}" -n "${NAMESPACE}" --reuse-values \
        --set "${SETARG}" >/dev/null 2>&1 && st=OK || st=FAIL
      t1=$(now_s); record "${rep}" t_rollout "$(elapsed "$t0" "$t1")" "${st}" "helm upgrade --set ${SETARG}"
      t0=$(now_s); wait_pods_ready && st=OK || st=FAIL; t1=$(now_s)
      record "${rep}" t_ready "$(elapsed "$t0" "$t1")" "${st}" "incluye pull de la imagen nueva"
      ;;
    overlay)
      # Update = re-transfer de la capa que contiene los pesos YOLO. Se invalida
      # el marker de la capa deps en el hostPath del edge y se reinicia el runtime:
      # el Init Container detecta el marker ausente y re-descarga SOLO esa capa.
      t0=$(now_s)
      ssh -o BatchMode=yes -o ConnectTimeout=8 "${EDGE_PURGE_HOST}" \
        "sudo -n /bin/rm -rf ${OVERLAY_HOSTPATH:?}/.markers/deps* ${OVERLAY_HOSTPATH:?}/deps* 2>/dev/null; true" \
        >/dev/null 2>&1 && st=OK || st=FAIL
      t1=$(now_s); record "${rep}" t_rollout "$(elapsed "$t0" "$t1")" "${st}" "invalidacion marker capa deps (edge)"
      t0=$(now_s)
      kubectl rollout restart statefulset -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" >/dev/null 2>&1
      wait_pods_ready && st=OK || st=FAIL
      t1=$(now_s); record "${rep}" t_ready "$(elapsed "$t0" "$t1")" "${st}" "re-descarga de la capa + arranque"
      ;;
    dynamic-loader)
      POD="${RELEASE}-0"
      EXEC="kubectl exec -n ${NAMESPACE} ${POD} -c orchestrator --"
      MODEL_PATH="/opt/models/yolov8n.pt"
      if [ -n "${NEW_WEIGHTS_LOCAL}" ]; then
        t0=$(now_s)
        kubectl cp "${NEW_WEIGHTS_LOCAL}" "${NAMESPACE}/${POD}:/tmp/yolo_new.pt" -c component-host && st=OK || st=FAIL
        t1=$(now_s); record "${rep}" t_transfer "$(elapsed "$t0" "$t1")" "${st}" "kubectl cp pesos nuevos"
        MODEL_PATH="/tmp/yolo_new.pt"
      else
        record "${rep}" t_transfer "NA" "SKIP" "sin NEW_WEIGHTS_LOCAL; se recarga el mismo model_path"
      fi
      t0=$(now_s)
      ${EXEC} curl -sX POST http://localhost:5000/unload -H 'Content-Type: application/json' \
        -d '{"module":"yolo"}' >/dev/null 2>&1
      ${EXEC} curl -sX POST http://localhost:5000/load -H 'Content-Type: application/json' \
        -d "{\"module\":\"yolo\",\"parameters\":{\"model_path\":\"${MODEL_PATH}\",\"conf\":0.25,\"filter_classes\":\"0,56,60\",\"publish_debug_image\":true,\"publish_metrics\":true}}" \
        | grep -q '"status"' && st=OK || st=FAIL
      t1=$(now_s); record "${rep}" t_rollout "$(elapsed "$t0" "$t1")" "${st}" "unload+load via orchestrator"
      record "${rep}" t_ready "0.00" "OK" "sin pods nuevos: el swap es intra-proceso"
      ;;
  esac

  sleep 30   # post-operación: dejar que la sonda capture la recuperación
  stop_gap_probe
  record "${rep}" t_gap_max "${GAP_MAX}" "OK" "hueco max en /benchmark/latency_ms (interrupcion percibida)"

  # Rollback por la misma vía
  if [ "${DO_ROLLBACK}" = "true" ]; then
    case "${PATTERN}" in
      monolithic|microservices)
        t0=$(now_s)
        helm rollback "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 && wait_pods_ready && st=OK || st=FAIL
        t1=$(now_s); record "${rep}" t_rollback "$(elapsed "$t0" "$t1")" "${st}" "helm rollback" ;;
      overlay)
        record "${rep}" t_rollback "NA" "SKIP" "el rollback de capa equivale a otra invalidacion+restart (simetrico a t_ready)" ;;
      dynamic-loader)
        POD="${RELEASE}-0"; EXEC="kubectl exec -n ${NAMESPACE} ${POD} -c orchestrator --"
        t0=$(now_s)
        ${EXEC} curl -sX POST http://localhost:5000/unload -H 'Content-Type: application/json' -d '{"module":"yolo"}' >/dev/null 2>&1
        ${EXEC} curl -sX POST http://localhost:5000/load -H 'Content-Type: application/json' \
          -d '{"module":"yolo","parameters":{"model_path":"/opt/models/yolov8n.pt","conf":0.25,"filter_classes":"0,56,60","publish_debug_image":true,"publish_metrics":true}}' \
          | grep -q '"status"' && st=OK || st=FAIL
        t1=$(now_s); record "${rep}" t_rollback "$(elapsed "$t0" "$t1")" "${st}" "reload pesos originales" ;;
    esac
  fi
done

echo "Hecho: ${CSV} (gap crudo en ${GAP_CSV})"
