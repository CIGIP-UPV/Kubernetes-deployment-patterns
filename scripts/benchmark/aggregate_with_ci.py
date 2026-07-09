#!/usr/bin/env python3
"""
aggregate_with_ci.py — Agregación estadística de campañas (R1.9 / R1.10).

Recorre results/_campaigns/<TS>/ y produce, por (regimen, patron, metrica):
mean, std, n, CI95 (t de Student), p50, p95, min, max. Tambien deriva:

  dropped_frames   = max(frames_published) - max(frames_received) por ciclo
  drop_rate_pct    = 100 * dropped / published
  queue_wait_ms    = estadisticos de la espera en cola (staleness)

El regimen se lee del fichero REGIME.txt de cada campaña (warm | image-cold |
pristine; las campañas anteriores a la revision, sin REGIME.txt, se etiquetan
"legacy-unknown" y NUNCA se mezclan con las nuevas — exigencia R1.2).
Si existe sensitivity_index_*.csv, tambien agrega por trigger_interval_s.

Uso:
  python3 scripts/benchmark/aggregate_with_ci.py [--campaigns results/_campaigns] \
      [--out results/aggregated_stats.csv]

Sin dependencias externas (solo stdlib), para poder correr en kb1 tal cual.
"""
import argparse
import csv
import math
import os
import sys
from collections import defaultdict
from pathlib import Path
from statistics import mean, stdev

# t de Student de dos colas al 95% para n-1 grados de libertad (n=2..30).
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
       7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
       13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
       19: 2.093, 20: 2.086, 24: 2.064, 29: 2.045}


def t95(df: int) -> float:
    if df <= 0:
        return float("nan")
    if df in T95:
        return T95[df]
    keys = sorted(T95)
    for k in keys:
        if df < k:
            return T95[k]
    return 1.96


def percentile(vals, p):
    if not vals:
        return math.nan
    s = sorted(vals)
    k = (len(s) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return s[int(k)]
    return s[f] * (c - k) + s[c] * (k - f)


def summarize(vals):
    n = len(vals)
    if n == 0:
        return dict(n=0, mean=math.nan, std=math.nan, ci95=math.nan,
                    p50=math.nan, p95=math.nan, vmin=math.nan, vmax=math.nan)
    m = mean(vals)
    sd = stdev(vals) if n > 1 else 0.0
    ci = t95(n - 1) * sd / math.sqrt(n) if n > 1 else math.nan
    return dict(n=n, mean=m, std=sd, ci95=ci,
                p50=percentile(vals, 0.5), p95=percentile(vals, 0.95),
                vmin=min(vals), vmax=max(vals))


def read_regime(campaign_dir: Path) -> str:
    f = campaign_dir / "REGIME.txt"
    if f.exists():
        return f.read_text().strip()
    return "legacy-unknown"


def read_comparison(campaign_dir: Path):
    """Filas del comparison.csv de una campaña (una por patron)."""
    f = campaign_dir / "comparison.csv"
    if not f.exists():
        return []
    with open(f, newline="") as fh:
        return [r for r in csv.DictReader(fh) if r.get("status", "").strip() == "ok"]


def read_dashboard_samples(campaign_dir: Path, pattern: str):
    """Muestras crudas (timestamp,topic,value) del ciclo de un patron."""
    f = campaign_dir / pattern / "dashboard_samples.csv"
    out = defaultdict(list)
    if not f.exists():
        return out
    with open(f, newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                out[row["topic"]].append(float(row["value"]))
            except (KeyError, ValueError):
                continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--campaigns", default="results/_campaigns")
    ap.add_argument("--out", default="results/aggregated_stats.csv")
    args = ap.parse_args()

    base = Path(args.campaigns)
    if not base.is_dir():
        print(f"ERROR: no existe {base} (¿has ejecutado alguna campaña?)", file=sys.stderr)
        return 2

    # (regime, pattern, metric) -> lista de valores POR CICLO (un valor/ciclo)
    per_cycle = defaultdict(list)
    # (regime, pattern, metric) -> muestras crudas concatenadas (distribuciones)
    raw = defaultdict(list)

    campaigns = sorted(d for d in base.iterdir() if d.is_dir())
    for camp in campaigns:
        regime = read_regime(camp)
        for row in read_comparison(camp):
            pat = row["pattern"]
            for col in ("t_install_e2e_s", "t_inf_avg_ms", "f_fps_pub",
                        "t_e2e_avg_ms", "j_inf_ms", "u_cpu_avg_pct",
                        "u_gpu_avg_pct", "u_ram_avg_pct"):
                try:
                    per_cycle[(regime, pat, col)].append(float(row[col]))
                except (KeyError, ValueError, TypeError):
                    continue
            samples = read_dashboard_samples(camp, pat)
            for topic, vals in samples.items():
                raw[(regime, pat, f"raw:{topic}")].extend(vals)
            # Derivadas de la instrumentacion R1.10 (contadores acumulados)
            pub = samples.get("/camera/frames_published", [])
            rec = samples.get("/benchmark/frames_received", [])
            if pub and rec:
                dropped = max(pub) - max(rec)
                per_cycle[(regime, pat, "dropped_frames")].append(dropped)
                if max(pub) > 0:
                    per_cycle[(regime, pat, "drop_rate_pct")].append(
                        100.0 * dropped / max(pub))
            qw = samples.get("/benchmark/queue_wait_ms", [])
            if qw:
                per_cycle[(regime, pat, "queue_wait_ms_mean")].append(mean(qw))
                per_cycle[(regime, pat, "queue_wait_ms_p95")].append(
                    percentile(qw, 0.95))

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["regime", "pattern", "metric", "n", "mean", "std",
                    "ci95_halfwidth", "p50", "p95", "min", "max", "level"])
        for (regime, pat, metric), vals in sorted(per_cycle.items()):
            s = summarize(vals)
            w.writerow([regime, pat, metric, s["n"], f"{s['mean']:.4f}",
                        f"{s['std']:.4f}", f"{s['ci95']:.4f}", f"{s['p50']:.4f}",
                        f"{s['p95']:.4f}", f"{s['vmin']:.4f}", f"{s['vmax']:.4f}",
                        "per-cycle"])
        for (regime, pat, metric), vals in sorted(raw.items()):
            s = summarize(vals)
            w.writerow([regime, pat, metric, s["n"], f"{s['mean']:.4f}",
                        f"{s['std']:.4f}", f"{s['ci95']:.4f}", f"{s['p50']:.4f}",
                        f"{s['p95']:.4f}", f"{s['vmin']:.4f}", f"{s['vmax']:.4f}",
                        "raw-samples"])

    print(f"[aggregate] {len(campaigns)} campañas → {args.out}")
    print("[aggregate] Regla R1.2: no mezclar filas de regimenes distintos en una misma tabla del paper.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
