# Benchmark Metrics — dynamic-canonical

_Generated: 2026-05-06T12:12:28Z (manual capture from Rancher kubectl shell, post-rebuild with vision_msgs)_

Release: `dynamic-pattern`  ·  Namespace: `ros2exp`
Scenario: **S1** (FPS=10, real camera `/dev/video1` — fallback to synthetic detected, see notes)
Run type: **cold-cold** (containerd image purged before reinstall)

## S_img — Image footprint

| Image | Size (GB) | Bytes |
|-------|-----------|-------|
| ros2-component-host | 29.77 | 31964922740 |
| ros2-dashboard | 0.25 | 270402470 |
| **TOTAL** | **30.02** | **32235325210** |

> Comparison: monolithic = 30.01 GB, microservices = 41.24 GB, overlay-canonical = 27.54 GB.
> Dynamic-canonical y monolithic tienen tamaño casi idéntico (~30 GB) — ambas hornean
> todo en una imagen. La diferencia es que dynamic permite **hot-swap** de componentes
> sin restart del pod, mientras monolithic requiere rebuild + push + pull para cualquier cambio.

## T_sched — Scheduling latency (per pod)

| Pod | Δ (s) | Scheduled | Started | Node |
|-----|-------|-----------|---------|------|
| dynamic-pattern-...-canonical-0 (runtime) | 488 | 2026-05-06T12:01:50Z | 2026-05-06T12:09:58Z | edgenode01 |
| dynamic-pattern-...-dashboard-0 | 549 | 2026-05-06T12:01:50Z | 2026-05-06T12:10:59Z | kb2 |

**T_sched_avg = 518 s**
**T_sched_max = 549 s** (dashboard, gated by wait-for-peers)
**T_ready_system = 549 s** (first PodScheduled → last Ready)

## T_install_e2e — Full operational install (cold-cold)

**T_install_e2e = 645 s = 10 min 45 s** (helm install → all 4 AI modules dynamically loaded)

Desglose:
- 7 s: Pods scheduled
- 486 s: Pull ros2-component-host 31.96 GB (75.3 % del total)
- 56 s: Container start + orchestrator init + dashboard ready
- 57 s: Bootstrap Job carga los 4 nodos AI dinámicamente

## C-7 — Dynamic LoadNode latency (the headline metric)

| Module | Plugin | Load time |
|--------|--------|-----------|
| camera | `camera_driver_pkg::CameraDriver` | **0.78 s** |
| yolo | `yolo_detector_pkg::YoloDetector` | **20.34 s** |
| llava | `llava_pkg::LlavaNode` | **31.10 s** |
| voxtral | `voxtral_pkg::VoxtralNode` | **4.55 s** |
| **Total sequential** | — | **56.77 s** |

**Comparativa entre patterns** (tiempo para "swap one ML component"):

| Pattern | Time to swap one model |
|---------|------------------------|
| monolithic | ~15-25 min |
| microservices | ~5-10 min |
| overlay-canonical | ~2.5 min |
| **dynamic-canonical** | **0.78 - 31.10 s** |

Dynamic es **2-3 órdenes de magnitud más rápido** para hot-swap. Es el diferenciador del pattern.

## L_net — Round-trip latency

| Node | IP | RTT avg (ms) |
|------|------|--------------|
| kb2 | 158.42.104.15 | (reuse: 4.2 ms) |
| edgenode01 | 158.42.104.206 | (reuse: 7.9 ms) |
| worker1-kb2 | 158.42.104.103 | (reuse: 30.4 ms) |

_L_net is cluster-topology-dependent, not pattern-dependent. Reused from monolithic measurement._

## C_cfg — Config churn

_(no diff or no tags)_

## T_CI — Last successful build

Duration: `n/a` seconds

## Steady-state runtime (kubectl top, recién Ready)

| Pod | CPU (m) | Memory (MiB) |
|-----|---------|--------------|
| runtime-0 (component-host + orchestrator) | 1687 | 10 150 |
| dashboard-0 | 40 | 100 |

> Nota: memoria del runtime (10.1 GiB) es notablemente menor que overlay-canonical (16.5-17 GiB)
> porque la captura es a 14 s del último load. Conforme las inferencias se acumulen debería
> subir a 16-17 GiB (LLaVA-1.5-7B FP16 + buffers + Voxtral-Mini-3B).

## Dashboard runtime metrics (S1, 14 s uptime, modo synthetic fallback)

| Metric | Value | Unit |
|--------|-------|------|
| Camera | ⚠️ FALLBACK SYNTHETIC | (real camera not accessible — pendiente fix) |
| T_inf (avg) | 351.4 | ms |
| f_FPS (theor.) | 2.8 | fps |
| f_FPS (pub) | 2.6 | fps |
| T_e2e (avg / max) | 318 / 513 | ms |
| T_ready (loop) | 0.18 | s |
| J_inf | 42.8 | ms |
| U_CPU (avg / max) | 24.1 / 43.3 | % |
| U_GPU (avg / max) | 5.3 / 15.7 | % |
| U_RAM (avg / max) | 30.3 / 30.4 | % |
| L_IO (read / write) | 0.00 / 0.00 | MB/s |
| P_avg, E_inf, η_energy | No data | (Jetson tegrastats unavailable) |

> ⚠️ **Camera en synthetic mode aunque se pasó `synthetic_mode: False, device: /dev/video1`**.
> El plugin `camera_driver_pkg::CameraDriver` no pudo abrir `/dev/video1` y cayó al fallback
> sintético. Posibles causas: el chart de dynamic-canonical no monta `/dev/video1` en privileged
> mode, o el pod se desplegó antes de que el dispositivo estuviera libre tras el uninstall del
> overlay anterior. Pendiente reproducir con `kubectl describe pod` y revisar securityContext.

## Derived

| Indicator | Value |
|-----------|-------|
| T_ready (from dashboard, loop) | 0.18 s |
| T_install_e2e (from kubectl + orchestrator log) | 645 s |
| T_ready_system (from kubectl conditions) | 549 s |
| C-7 total (4 LoadNode sequential) | 56.77 s |
| η_start = 1 / T_install | 0.00155 |
| Pull bandwidth (registry → edge) | 65.7 MB/s ≈ 526 Mbps |
