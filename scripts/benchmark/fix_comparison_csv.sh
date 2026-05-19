#!/usr/bin/env bash
# =============================================================================
# fix_comparison_csv.sh — Reconstruye comparison.csv de un ciclo a partir
#                        de los CSV crudos por patrón.
# =============================================================================
# El run_full_campaign.sh original tenía un bug: concatenaba la fila final
# del dashboard_aggregate.csv (que Python escribe con CRLF) directamente
# en una cadena bash. El \r final hacía que la línea apareciera
# truncada al imprimirla. Los datos crudos están bien; solo el comparison
# está corrupto.
#
# Este script reescribe comparison.csv a partir de:
#   <campaign_dir>/<pattern>/T_zero.txt
#   <campaign_dir>/<pattern>/T_fin.txt
#   <campaign_dir>/<pattern>/dashboard_aggregate.csv  (limpio de \r)
#   <campaign_dir>/<pattern>/t_ready.csv               (si existe)
#   dist/metrics/<pattern>.metrics.csv                 (si existe — S_img)
#
# Uso:
#   bash scripts/benchmark/fix_comparison_csv.sh <campaign_dir>
#
# Ejemplos:
#   bash scripts/benchmark/fix_comparison_csv.sh results/_campaigns/20260518-094127
#
#   # O para arreglar todos los ciclos de una meta-campaña a la vez:
#   for d in results/_campaigns/2026*/; do
#     [ -f "$d/comparison.csv" ] && bash scripts/benchmark/fix_comparison_csv.sh "$d"
#   done
# =============================================================================
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Uso: $0 <campaign_dir>"
  exit 1
fi

CAMPAIGN_DIR="$1"
if [ ! -d "${CAMPAIGN_DIR}" ]; then
  echo "ERROR: no existe el directorio ${CAMPAIGN_DIR}"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${CAMPAIGN_DIR}/comparison.csv"
BACKUP="${CAMPAIGN_DIR}/comparison.broken.csv"

if [ -f "${OUT}" ]; then
  cp "${OUT}" "${BACKUP}"
  echo "Backup del CSV corrupto: ${BACKUP}"
fi

echo "pattern,t_zero,t_fin,t_install_e2e_s,t_ready_system_s,s_img_total_gb,t_inf_avg_ms,f_fps_pub,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,u_ram_avg_pct,run_dir,status,notes" > "${OUT}"

for pattern in monolithic microservices overlay-canonical dynamic-canonical; do
  PDIR="${CAMPAIGN_DIR}/${pattern}"
  [ -d "${PDIR}" ] || continue

  T_ZERO=""
  T_FIN=""
  T_INSTALL=""
  T_READY_SYSTEM=""
  S_IMG=""
  AGG=",,,,,,"
  STATUS=""
  NOTES=""

  [ -f "${PDIR}/T_zero.txt" ] && T_ZERO=$(tr -d '\r\n' < "${PDIR}/T_zero.txt")
  [ -f "${PDIR}/T_fin.txt"  ] && T_FIN=$(tr -d '\r\n' < "${PDIR}/T_fin.txt")

  if [ -n "${T_ZERO}" ] && [ -n "${T_FIN}" ]; then
    Z=$(date -u -d "${T_ZERO}" +%s 2>/dev/null || gdate -u -d "${T_ZERO}" +%s 2>/dev/null || echo "")
    F=$(date -u -d "${T_FIN}"  +%s 2>/dev/null || gdate -u -d "${T_FIN}"  +%s 2>/dev/null || echo "")
    [ -n "${Z}" ] && [ -n "${F}" ] && T_INSTALL=$((F - Z))
  fi

  if [ -f "${PDIR}/dashboard_aggregate.csv" ]; then
    AGG=$(tail -1 "${PDIR}/dashboard_aggregate.csv" | tr -d '\r')
    STATUS="ok"
  else
    STATUS="no_samples"
  fi

  if [ -f "${PDIR}/t_ready.csv" ]; then
    T_READY_SYSTEM=$(awk -F',' 'NR>1 {if($4>max) max=$4} END {print max}' "${PDIR}/t_ready.csv" | tr -d '\r')
  fi

  if [ -f "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" ]; then
    S_IMG=$(tail -1 "${PROJECT_ROOT}/dist/metrics/${pattern}.metrics.csv" | awk -F',' '{print $3}' | tr -d '\r')
  fi

  echo "${pattern},${T_ZERO},${T_FIN},${T_INSTALL},${T_READY_SYSTEM},${S_IMG},${AGG},${PDIR},${STATUS},${NOTES}" >> "${OUT}"
done

echo "Regenerado: ${OUT}"
echo ""
echo "Contenido:"
column -t -s ',' "${OUT}" 2>/dev/null || cat "${OUT}"
