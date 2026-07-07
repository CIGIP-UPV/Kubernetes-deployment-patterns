# Measurement data

This folder contains the measurement data of the experimental
campaign reported in the article. Each pattern has its own
subdirectory with a `summary.csv` that lists every metric reported in
the paper for that pattern, together with the mean, standard
deviation, number of replicates, regime and a pointer to the figure
or table of the article where the value appears.

## Layout

```
results/
├── README.md                         # this file
├── monolithic/
│   └── summary.csv                   # all metrics reported for the monolithic pattern
├── microservices/
│   └── summary.csv                   # all metrics reported for the microservices pattern
├── dynamic-loader/
│   ├── summary.csv                   # all metrics reported for the dynamic loading pattern
│   └── load-unload/
│       └── load_unload_per_module.csv  # per-module hot-swap latencies (Section V-E / H2)
├── overlay/
│   └── summary.csv                   # all metrics reported for the overlay pattern (with opts)
└── _campaigns/                       # raw rosbridge samples per cycle (synced from kb2)
    └── <TS>/<pattern>/
```

## Provenance of the numbers

- **Mega-campaign `20260526-065922`** is the source of every per-pattern
  runtime number (T_inf, FPS, T_e2e, J_inf, U_CPU, U_GPU, U_RAM) and
  of the install times of monolithic, microservices and dynamic.
  Configuration: chart defaults for the four patterns, deterministic
  LLaVA trigger driver firing every 30 s, camera at 20 fps native.
  Replicates: 5 warm + 3 cold-cold per pattern.
- **Campaign `20260601-081148`** is the source of the overlay install
  times (Figure 3 / Section V-B), including the operating-point warm
  value of 71 ± 0.5 s reported in the article. Configuration: overlay
  chart with `overlay.layered=true`, `overlay.pipeline=true`,
  `overlayMount.kind=hostPath`. Replicates: 5 warm + 3 cold-cold.
- **`dynamic-loader/load-unload/load_unload_per_module.csv`** is
  the source of the per-module hot-swap latencies that sustain H2
  (camera 0.78 s, YOLOv8-nano 20.34 s, LLaVA-1.5-7B 31.10 s, Voxtral
  4.55 s; sequential total 56.77 s). Measured directly from the POST
  request orchestrator log of the dynamic pattern.

## Reading a per-pattern `summary.csv`

The columns are:

| Column | Meaning |
|---|---|
| `metric` | Name of the metric (T_install, T_inf, f_FPS, J_inf, U_CPU, U_GPU, U_RAM, S_img, OTA_payload, hot_swap_*). |
| `unit` | Unit of the metric (s, ms, fps, %, GB). |
| `mean` | Sample mean across the replicates. |
| `std` | Sample standard deviation. Blank when n=1. |
| `n` | Number of replicates the mean and std are computed over. |
| `regime` | Conditions of the measurement (warm / cold-cold / steady state / etc.). |
| `source` | Campaign or measurement file from which the value is derived. |
| `table_or_figure_in_paper` | Pointer to the figure or table of the article that displays this value. |

## Reproducing the campaign

The full reproduction pipeline is documented in the top-level
`README.md` of the repository. The aggregated CSVs are produced by
`scripts/benchmark/aggregate_meta_campaign.sh` from the raw per-cycle
artifacts in `_campaigns/<TS>/<pattern>/`.
