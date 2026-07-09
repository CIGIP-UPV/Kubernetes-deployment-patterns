#!/usr/bin/env bash
# =============================================================================
# run_sensitivity_campaign.sh — Barrido del periodo del trigger LLaVA
# =============================================================================
# Responde R1.7 / R2.2 / R3.3: sensibilidad de las metricas runtime al periodo
# del trigger determinista de LLaVA. Ejecuta campañas warm completas (los 4
# patrones, decision D6) para cada periodo de TRIGGER_INTERVALS, N_PER_POINT
# veces por punto.
#
# El punto de 30 s en regimen warm sirve ademas como linea base runtime
# regenerada (plan B de R1.9).
#
# Coste estimado con defaults (4 periodos × 3 ciclos × ~1 h): ~2 dias.
#   nohup bash scripts/benchmark/run_sensitivity_campaign.sh > sensitivity.log 2>&1 &
#
# Variables de entorno:
#   TRIGGER_INTERVALS  Default "30 60 120 300" (segundos; los del manuscrito)
#   N_PER_POINT        Default 3
#   PAUSE_BETWEEN      Default 900 s
#   PATTERNS           Default los 4 (heredada por run_full_campaign.sh)
#   WARMUP_SECONDS     Default 600. NOTA: con periodos largos (300 s) el warmup
#                      de 10 min solo permite ~2 disparos; se amplia
#                      automaticamente a max(600, 3*intervalo) salvo que se fije.
#   SAMPLE_SECONDS     Default max(180, 2*intervalo) por el mismo motivo.
# Abortar entre ciclos: touch /tmp/STOP_SENSITIVITY
# =============================================================================
set -uo pipefail

TRIGGER_INTERVALS="${TRIGGER_INTERVALS:-30 60 120 300}"
N_PER_POINT="${N_PER_POINT:-3}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-900}"
ABORT_FILE="${ABORT_FILE:-/tmp/STOP_SENSITIVITY}"
WARMUP_FIXED="${WARMUP_SECONDS:-}"
SAMPLE_FIXED="${SAMPLE_SECONDS:-}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAMPAIGN="${PROJECT_ROOT}/scripts/benchmark/run_full_campaign.sh"
INDEX_CSV="${PROJECT_ROOT}/results/_campaigns/sensitivity_index_$(date +%Y%m%d-%H%M%S).csv"
mkdir -p "$(dirname "${INDEX_CSV}")"
echo "trigger_interval_s,cycle,warmup_s,sample_s,started_at,finished_at,exit_code" > "${INDEX_CSV}"

for interval in ${TRIGGER_INTERVALS}; do
  # Ventanas adaptadas al periodo: garantizar >=3 disparos en warmup y >=2 en
  # la ventana de muestreo, manteniendo los minimos de la campaña original.
  warmup="${WARMUP_FIXED:-$(( interval * 3 > 600 ? interval * 3 : 600 ))}"
  sample="${SAMPLE_FIXED:-$(( interval * 2 > 180 ? interval * 2 : 180 ))}"

  for i in $(seq 1 "${N_PER_POINT}"); do
    if [ -e "${ABORT_FILE}" ]; then
      echo "[sens] Abort file detectado; parando."
      rm -f "${ABORT_FILE}"
      exit 0
    fi
    echo "[sens] ═══ Trigger ${interval}s — ciclo ${i}/${N_PER_POINT} (warmup=${warmup}s sample=${sample}s) ═══"
    t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    LLAVA_TRIGGER_INTERVAL="${interval}" \
    WARMUP_SECONDS="${warmup}" \
    SAMPLE_SECONDS="${sample}" \
    COLD_MODE=warm \
    KEEP_DEPLOYMENT=false \
      bash "${CAMPAIGN}"
    rc=$?
    t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${interval},${i},${warmup},${sample},${t0},${t1},${rc}" >> "${INDEX_CSV}"
    echo "[sens] Ciclo terminado (rc=${rc}). Pausa ${PAUSE_BETWEEN}s..."
    sleep "${PAUSE_BETWEEN}"
  done
done
echo "[sens] Barrido completo. Indice: ${INDEX_CSV}"
