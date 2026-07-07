#!/usr/bin/env bash
# =============================================================================
# aggregate_meta_campaign.sh — Une las comparison.csv de varios ciclos en uno
# =============================================================================
# Lee el _summary_<TS>.csv generado por run_n_campaigns.sh, recorre cada
# results/_campaigns/<TS_ciclo>/comparison.csv y produce un agregado:
#
#   dist/metrics/meta_campaign_<TS>.csv
#       una fila por (ciclo, patrón) — datos crudos.
#
#   dist/metrics/meta_campaign_<TS>_summary.csv
#       una fila por patrón con media, desviación y min/max sobre los
#       N ciclos válidos (status=ok). Esto es lo que se usa para detectar
#       outliers y reportar en el paper.
#
# Uso:
#   bash scripts/benchmark/aggregate_meta_campaign.sh <ruta-a-_summary_*.csv>
# =============================================================================
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Uso: $0 <results/_campaigns/_summary_*.csv>"
  exit 1
fi

SUMMARY_FILE="$1"
if [ ! -f "${SUMMARY_FILE}" ]; then
  echo "ERROR: no existe ${SUMMARY_FILE}"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
META_TS="$(basename "${SUMMARY_FILE}" .csv | sed 's/^_summary_//')"
OUT_RAW="${PROJECT_ROOT}/dist/metrics/meta_campaign_${META_TS}.csv"
OUT_SUM="${PROJECT_ROOT}/dist/metrics/meta_campaign_${META_TS}_summary.csv"

mkdir -p "${PROJECT_ROOT}/dist/metrics"

# Cabecera del agregado bruto: cycle, regimen + columnas de comparison.csv
echo "cycle,regimen,pattern,t_zero,t_fin,t_install_e2e_s,t_ready_system_s,s_img_total_gb,t_inf_avg_ms,f_fps_pub,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,u_ram_avg_pct,status,notes" > "${OUT_RAW}"

# Por cada fila del summary (cada ciclo)
while IFS=, read -r cycle regimen campaign_dir started_at finished_at duration; do
  [ "${cycle}" = "cycle" ] && continue
  cmp="${campaign_dir}/comparison.csv"
  if [ ! -f "${cmp}" ]; then
    echo "WARNING: falta ${cmp}, saltando ciclo ${cycle}"
    continue
  fi
  # Cabecera del comparison.csv:
  # pattern,t_zero,t_fin,t_install_e2e_s,t_ready_system_s,s_img_total_gb,
  # t_inf_avg_ms,f_fps_pub,t_e2e_avg_ms,j_inf_ms,u_cpu_avg_pct,u_gpu_avg_pct,
  # u_ram_avg_pct,run_dir,status,notes
  tail -n +2 "${cmp}" | while IFS=, read -r pat tz tf tinst tready simg tinf fps te2e jinf ucpu ugpu uram rd st nt; do
    echo "${cycle},${regimen},${pat},${tz},${tf},${tinst},${tready},${simg},${tinf},${fps},${te2e},${jinf},${ucpu},${ugpu},${uram},${st},${nt}" >> "${OUT_RAW}"
  done
done < "${SUMMARY_FILE}"

echo "Agregado bruto escrito en: ${OUT_RAW}"
echo "  filas: $(($(wc -l < "${OUT_RAW}") - 1))"

# Agregación estadística por (pattern, regimen) usando python.
python3 - "${OUT_RAW}" "${OUT_SUM}" <<'PYEOF'
import csv, sys, statistics
raw_path, out_path = sys.argv[1], sys.argv[2]

# Métricas numéricas a resumir.
metrics = ["t_install_e2e_s", "t_ready_system_s", "s_img_total_gb",
           "t_inf_avg_ms", "f_fps_pub", "t_e2e_avg_ms", "j_inf_ms",
           "u_cpu_avg_pct", "u_gpu_avg_pct", "u_ram_avg_pct"]

groups = {}   # (pattern, regimen) -> {metric: [values]}
with open(raw_path) as f:
    r = csv.DictReader(f)
    for row in r:
        if row.get("status") != "ok":
            continue
        key = (row["pattern"], row["regimen"])
        bucket = groups.setdefault(key, {m: [] for m in metrics})
        for m in metrics:
            v = row.get(m, "").strip()
            try:
                bucket[m].append(float(v))
            except (ValueError, TypeError):
                pass

# Salida: pattern, regimen, metric, n, mean, stdev, min, max
with open(out_path, "w", newline="") as out:
    w = csv.writer(out)
    w.writerow(["pattern", "regimen", "metric", "n", "mean", "stdev", "min", "max"])
    for (pat, reg) in sorted(groups.keys()):
        for m in metrics:
            vals = groups[(pat, reg)][m]
            n = len(vals)
            if n == 0:
                w.writerow([pat, reg, m, 0, "", "", "", ""])
                continue
            mean = statistics.mean(vals)
            sd   = statistics.stdev(vals) if n >= 2 else 0.0
            w.writerow([pat, reg, m, n, f"{mean:.3f}", f"{sd:.3f}",
                        f"{min(vals):.3f}", f"{max(vals):.3f}"])

print(f"Resumen estadístico escrito en: {out_path}")
PYEOF
