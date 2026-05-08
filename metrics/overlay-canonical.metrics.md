# Benchmark Metrics — overlay-canonical

_Generated: 2026-05-06T08:06:00Z (manual capture from Rancher kubectl shell)_

Release: `over-pattern`  ·  Namespace: `ros2exp`
Scenario: **S1** (FPS=10, real camera `/dev/video1`)
Run type: **warm restart** (after `helm upgrade --set camera.syntheticMode=false` + `kubectl delete pod`)

## S_img — Image footprint

| Image | Size (GB) | Bytes |
|-------|-----------|-------|
| ros2-base | 2.24 | 2408164773 |
| ros2-overlay-pack | 25.05 | 26902423020 |
| ros2-dashboard | 0.25 | 270402470 |
| **TOTAL** | **27.54** | **29580990263** |

> Comparison: monolithic = 30.01 GB, microservices = 41.24 GB.
> Overlay-canonical achieves the **smallest total** because the
> base layer (ros2-base 2.24 GB) is shared and immutable; only the
> overlay-pack carrier (25.05 GB) needs to be re-published per AI
> update. Net OTA payload for an overlay update = 25.05 GB
> (vs 29.76 GB rebuild for monolithic, vs N×Δ images for microservices).

## T_sched — Scheduling latency (per pod)

| Pod | Δ (s) | Scheduled | Started | Node |
|-----|-------|-----------|---------|------|
| over-pattern-...-overlay-server-7fd498c9qtd6 | 2 | 2026-05-06T07:36:41Z | 2026-05-06T07:36:43Z | worker1-kb2 |
| over-pattern-...-dashboard-0 | 69 | 2026-05-06T07:37:06Z | 2026-05-06T07:38:15Z | kb2 |
| over-pattern-...-canonical-0 (runtime) | 40 | 2026-05-06T07:38:41Z | 2026-05-06T07:39:21Z | edgenode01 |

**T_sched_avg = 37 s**
**T_ready_system = 160 s** (first PodScheduled → last Ready, warm restart)

## L_net — Round-trip latency

| Node | IP | RTT avg (ms) |
|------|------|--------------|
| kb2 | 158.42.104.15 | (reuse from monolithic: 4.202) |
| edgenode01 | 158.42.104.206 | (reuse from monolithic: 7.865) |
| worker1-kb2 | 158.42.104.103 | (reuse from monolithic: 30.404) |

_L_net is cluster-topology-dependent, not pattern-dependent.
Reused from monolithic measurement on 2026-05-04. Bandwidth (iperf3) must be measured manually._

## C_cfg — Config churn

_(no diff or no tags)_

## T_CI — Last successful build

Duration: `n/a` seconds

## Derived

| Indicator | Value |
|-----------|-------|
| T_ready (from dashboard) | 0.12 s |
| T_ready_system (from kubectl conditions, warm restart) | 160 s |
| T_ready_runtime_only (from kubectl conditions, warm restart) | 40 s |
| η_start (1 / (T_sched + T_ready)) | 0.0270 |
| R_deploy (T_sched / T_ready_system) | 0.231 |

## Steady-state (kubectl top, 26 min uptime)

| Pod | CPU (m) | Memory (MiB) |
|-----|---------|--------------|
| over-pattern-...-canonical-0 (runtime) | 1235 | 17264 |
| over-pattern-...-dashboard-0 | 222 | 112 |
| over-pattern-...-overlay-server-* | 1 | 13 |

## Dashboard runtime metrics (S1, real camera, 26 min uptime)

| Metric | Value | Unit |
|--------|-------|------|
| T_inf (avg) | 32.7 | ms |
| f_FPS (theor.) | 30.6 | fps |
| f_FPS (pub) | 10.2 | fps |
| T_e2e (avg) | 6089 | ms |
| T_e2e (max) | 59993 | ms |
| T_ready (loop) | 0.12 | s |
| J_inf (jitter) | 8.5 | ms |
| U_CPU (avg / max) | 21.2 / 45.3 | % |
| U_GPU (avg / max) | 51.7 / 99.9 | % |
| U_RAM (avg / max) | 33.3 / 33.7 | % |
| L_IO (read / write) | 0.12 / 0.03 | MB/s |
| P_avg, E_inf, η_energy | No data | (Jetson tegrastats unavailable) |

## Overlay extracted size on edge

| Path | Size |
|------|------|
| /opt/overlay | 34 GB |

> 34 GB extracted on the edge node from a 25.05 GB carrier image
> demonstrates the inflation factor of pip/torch installs and the
> baked-in HuggingFace cache (LLaVA-1.5-7B FP16 + Voxtral-Mini-3B).
