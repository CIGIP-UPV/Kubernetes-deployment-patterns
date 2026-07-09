#!/usr/bin/env bash
# =============================================================================
# run_coldstart_matrix.sh — Matriz de cold-start en 3 regimenes (R1.2)
# =============================================================================
# Ejecuta, para los 4 patrones, N campañas por regimen usando run_full_campaign.sh:
#   warm        (N_WARM, default 5)   caches intactos
#   image-cold  (N_IMAGECOLD, def. 3) purga containerd; hostPath del overlay persiste
#   pristine    (N_PRISTINE, def. 3)  purga containerd + hostPath (fully clean, R1.2)
#
# Ademas de responder R1.2/R3.1, la serie warm regenera la linea base runtime
# (plan B de R1.9 tras la perdida de los crudos historicos).
#
# Coste estimado con defaults: 5 warm (~1 h/u) + 3 image-cold (~1.5 h/u)
# + 3 pristine (~1.5-2 h/u por el bootstrap del overlay) + pausas ≈ 16-18 h.
# Pensado para nohup nocturno:
#   nohup bash scripts/benchmark/run_coldstart_matrix.sh > coldstart_matrix.log 2>&1 &
#
# Variables de entorno: N_WARM, N_IMAGECOLD, N_PRISTINE, PAUSE_BETWEEN (def. 900 s),
# PATTERNS, y todas las de run_full_campaign.sh (NAMESPACE, ROSBRIDGE_URL, ...).
# Abortar entre ciclos: touch /tmp/STOP_COLDSTART_MATRIX
# =============================================================================
set -uo pipefail

N_WARM="${N_WARM:-5}"
N_IMAGECOLD="${N_IMAGECOLD:-3}"
N_PRISTINE="${N_PRISTINE:-3}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-900}"
ABORT_FILE="${ABORT_FILE:-/tmp/STOP_COLDSTART_MATRIX}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAMPAIGN="${PROJECT_ROOT}/scripts/benchmark/run_full_campaign.sh"
INDEX_CSV="${PROJECT_ROOT}/results/_campaigns/coldstart_matrix_index_$(date +%Y%m%d-%H%M%S).csv"
mkdir -p "$(dirname "${INDEX_CSV}")"
echo "regime,cycle,started_at,finished_at,exit_code" > "${INDEX_CSV}"

run_cycles() {
  local regime=$1 n=$2
  for i in $(seq 1 "${n}"); do
    if [ -e "${ABORT_FILE}" ]; then
      echo "[matrix] Abort file detectado; parando antes de ${regime} ciclo ${i}."
      rm -f "${ABORT_FILE}"
      exit 0
    fi
    echo "[matrix] ═══ Regimen ${regime} — ciclo ${i}/${n} ═══"
    local t0 t1 rc
    t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # KEEP_DEPLOYMENT=false: cada ciclo debe partir de cluster vacio.
    COLD_MODE="${regime}" KEEP_DEPLOYMENT=false bash "${CAMPAIGN}"
    rc=$?
    t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${regime},${i},${t0},${t1},${rc}" >> "${INDEX_CSV}"
    echo "[matrix] Ciclo terminado (rc=${rc}). Pausa de ${PAUSE_BETWEEN}s..."
    sleep "${PAUSE_BETWEEN}"
  done
}

echo "[matrix] warm=${N_WARM} image-cold=${N_IMAGECOLD} pristine=${N_PRISTINE}"
run_cycles warm        "${N_WARM}"
run_cycles image-cold  "${N_IMAGECOLD}"
run_cycles pristine    "${N_PRISTINE}"
echo "[matrix] Matriz completa. Indice: ${INDEX_CSV}"
