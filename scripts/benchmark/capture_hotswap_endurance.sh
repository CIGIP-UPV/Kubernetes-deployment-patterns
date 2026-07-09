#!/usr/bin/env bash
# =============================================================================
# capture_hotswap_endurance.sh — Hot-swap repetido con vigilancia de memoria (R1.12)
# =============================================================================
# Ejecuta N ciclos de load→settle→unload por modulo sobre el dynamic-loader y,
# tras cada operacion, muestrea la memoria del proceso component_container
# (RSS y VmSize via /proc) y la memoria total del sistema en el edge. Registra
# fallos, tiempo de recuperacion y si el sistema vuelve a su estado base.
#
# Responde R1.12: fugas de interprete/CUDA tras swaps repetidos, tasa de fallo,
# comportamiento de recuperacion y estado final. Convierte ademas el dato de
# hot-swap de n=1 "manual" a n=N scripted (R1.9).
#
# Salida: results/dynamic-loader/endurance/<TS>/
#   endurance.csv   una fila por operacion:
#                   cycle,module,op,latency_s,status,rss_kb,vmsize_kb,
#                   mem_available_kb,components_loaded,timestamp
#   baseline.txt    estado inicial (componentes cargados + memoria)
#   final_check.txt estado final vs baseline
#
# Uso:
#   bash scripts/benchmark/capture_hotswap_endurance.sh [ciclos] [release] [namespace]
#   N_CYCLES=20 bash scripts/benchmark/capture_hotswap_endurance.sh
#
# Variables: N_CYCLES (def. 20), MODULES (def. "yolo llava voxtral"; camera se
# excluye por defecto para no matar el flujo de video del resto de modulos),
# SETTLE_S (def. 5), FULL_CYCLE_EVERY (def. 5: cada K ciclos se descargan y
# recargan TODOS los modulos en cadena, el escenario mas agresivo).
#
# Pre-requisitos: dynamic-loader desplegado con bootstrap completado.
# =============================================================================
set -uo pipefail

N_CYCLES="${N_CYCLES:-${1:-20}}"
RELEASE="${2:-dynamic-pattern}"
NAMESPACE="${3:-ros2exp}"
MODULES="${MODULES:-yolo llava voxtral}"
SETTLE_S="${SETTLE_S:-5}"
FULL_CYCLE_EVERY="${FULL_CYCLE_EVERY:-5}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${PROJECT_ROOT}/results/dynamic-loader/endurance/${TS}"
mkdir -p "${OUT_DIR}"
CSV="${OUT_DIR}/endurance.csv"

RUNTIME_POD="${RELEASE}-0"
ORCH_URL="http://localhost:5000"
EXEC_ORCH="kubectl exec -n ${NAMESPACE} ${RUNTIME_POD} -c orchestrator --"
EXEC_HOST="kubectl exec -n ${NAMESPACE} ${RUNTIME_POD} -c component-host --"

# Mismos parametros que bootstrap-job.yaml (mantener en sincronia).
declare -A MODULE_PARAMS=(
  [camera]='{"module":"camera","parameters":{"synthetic_mode":false}}'
  [yolo]='{"module":"yolo","parameters":{"model_path":"/opt/models/yolov8n.pt","conf":0.25,"filter_classes":"0,56,60","publish_debug_image":true,"publish_metrics":true}}'
  [llava]='{"module":"llava","parameters":{"hf_cache_dir":"/opt/huggingface_cache","load_in_4bit":true,"max_new_tokens":150,"trigger_on_yolo":true,"yolo_trigger_interval_s":30.0}}'
  [voxtral]='{"module":"voxtral","parameters":{"hf_cache_dir":"/opt/huggingface_cache","audio_mode":false}}'
)

# ── Memoria del proceso component_container (RSS/VmSize, kB) ────────────────
host_process_memory() {
  # Devuelve "rss_kb vmsize_kb" del proceso python que ejecuta el
  # component_container_isolated, o "NA NA" si no se encuentra.
  ${EXEC_HOST} sh -c '
    for d in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
      case "$cmd" in
        *component_container_isolated*)
          rss=$(awk "/^VmRSS:/{print \$2}"  "$d/status" 2>/dev/null)
          vsz=$(awk "/^VmSize:/{print \$2}" "$d/status" 2>/dev/null)
          echo "${rss:-NA} ${vsz:-NA}"
          exit 0 ;;
      esac
    done
    echo "NA NA"' 2>/dev/null || echo "NA NA"
}

# MemAvailable del edge (todo el nodo; la GPU del Jetson usa memoria unificada,
# asi que una fuga de CUDA aparece tambien aqui).
node_mem_available() {
  ${EXEC_HOST} sh -c 'awk "/^MemAvailable:/{print \$2}" /proc/meminfo' 2>/dev/null || echo "NA"
}

components_loaded() {
  ${EXEC_ORCH} curl -fsS --max-time 10 "${ORCH_URL}/list" 2>/dev/null | tr -d '\n' || echo "LIST_FAILED"
}

record() {
  # cycle,module,op,latency_s,status,rss,vmsize,mem_available,components,ts
  local mem avail comps
  mem=$(host_process_memory)
  avail=$(node_mem_available)
  comps=$(components_loaded | sed 's/,/;/g')
  echo "$1,$2,$3,$4,$5,${mem% *},${mem#* },${avail},\"${comps}\",$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${CSV}"
}

do_op() {
  # $1 cycle  $2 module  $3 op (load|unload) → latencia y status via API
  local cycle=$1 module=$2 op=$3 payload resp t0 t1 lat status
  if [ "${op}" = "load" ]; then
    payload="${MODULE_PARAMS[$module]}"
  else
    payload="{\"module\":\"${module}\"}"
  fi
  t0=$(date +%s.%N)
  resp=$(${EXEC_ORCH} curl -sX POST "${ORCH_URL}/${op}" \
          -H "Content-Type: application/json" -d "${payload}" 2>&1) || true
  t1=$(date +%s.%N)
  lat=$(awk -v s="$t0" -v e="$t1" 'BEGIN{printf "%.2f", e-s}')
  if echo "${resp}" | grep -q '"status"'; then status="OK"; else status="FAIL"; fi
  record "${cycle}" "${module}" "${op}" "${lat}" "${status}"
  echo "  [c${cycle}] ${module} ${op}: ${lat}s ${status}"
  # Recuperacion ante fallo: reintento unico tras 15 s (se registra aparte).
  if [ "${status}" = "FAIL" ]; then
    sleep 15
    t0=$(date +%s.%N)
    resp=$(${EXEC_ORCH} curl -sX POST "${ORCH_URL}/${op}" \
            -H "Content-Type: application/json" -d "${payload}" 2>&1) || true
    t1=$(date +%s.%N)
    lat=$(awk -v s="$t0" -v e="$t1" 'BEGIN{printf "%.2f", e-s}')
    if echo "${resp}" | grep -q '"status"'; then status="RECOVERED"; else status="FAIL_PERSISTENT"; fi
    record "${cycle}" "${module}" "${op}_retry" "${lat}" "${status}"
    echo "  [c${cycle}] ${module} ${op} retry: ${lat}s ${status}"
  fi
  sleep "${SETTLE_S}"
}

echo "============================================================"
echo " Hot-swap endurance: ${N_CYCLES} ciclos, modulos: ${MODULES}"
echo " Pod=${RUNTIME_POD} ns=${NAMESPACE} → ${OUT_DIR}"
echo "============================================================"

echo "cycle,module,op,latency_s,status,rss_kb,vmsize_kb,mem_available_kb,components_loaded,timestamp" > "${CSV}"

# Estado base
{
  echo "baseline components: $(components_loaded)"
  echo "baseline host memory (rss vms kB): $(host_process_memory)"
  echo "baseline MemAvailable (kB): $(node_mem_available)"
} | tee "${OUT_DIR}/baseline.txt"
record 0 all baseline 0 OK

for cycle in $(seq 1 "${N_CYCLES}"); do
  echo "─── Ciclo ${cycle}/${N_CYCLES} ───"
  if [ $((cycle % FULL_CYCLE_EVERY)) -eq 0 ]; then
    # Ciclo agresivo: descargar y recargar TODOS los modulos en cadena.
    for m in ${MODULES}; do do_op "${cycle}" "${m}" unload; done
    for m in ${MODULES}; do do_op "${cycle}" "${m}" load;   done
  else
    # Ciclo estandar: swap de cada modulo por separado (unload→load).
    for m in ${MODULES}; do
      do_op "${cycle}" "${m}" unload
      do_op "${cycle}" "${m}" load
    done
  fi
done

# Estado final vs baseline
{
  echo "final components: $(components_loaded)"
  echo "final host memory (rss vms kB): $(host_process_memory)"
  echo "final MemAvailable (kB): $(node_mem_available)"
  echo
  echo "Comparar con baseline.txt: una pendiente positiva sostenida de RSS o"
  echo "una caida sostenida de MemAvailable a componentes iguales indica fuga"
  echo "(R1.12). Analizar tendencia con scripts/benchmark/aggregate_with_ci.py."
} | tee "${OUT_DIR}/final_check.txt"
record $((N_CYCLES + 1)) all final 0 OK

echo "Hecho: ${CSV}"
