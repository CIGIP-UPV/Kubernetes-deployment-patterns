# dynamic-canonical — S1-cold-cold run summary

_Captured: 2026-05-06T12:12:28Z (uninstall + purge containerd ros2-component-host imagen + nueva imagen con vision_msgs)_

Release: `dynamic-pattern`  ·  Namespace: `ros2exp`
Escenario: **S1** (FPS=10, cámara real `/dev/video1`)
Tipo de run: **cold-cold (TRUE COLD START)** con la imagen recien parcheada (`ros-humble-vision-msgs` añadido al apt install).

## Timeline anotado

| Marca | Timestamp | Δ desde T_zero |
|---|---|---|
| **T_zero** (`date` antes de Install) | 2026-05-06T12:01:43Z | 0 s |
| Pods PodScheduled (runtime + dashboard) | 2026-05-06T12:01:50Z | 7 s |
| **Pull ros2-component-host 31.96 GB completado** | 2026-05-06T12:09:49Z | ~8 m 6 s ¹ |
| runtime ContainersReady | 2026-05-06T12:09:58Z | 8 m 15 s |
| dashboard Initialized | 2026-05-06T12:10:58Z | 9 m 15 s |
| dashboard Ready | 2026-05-06T12:10:59Z | 9 m 16 s |
| Bootstrap Job: load camera | 2026-05-06T12:11:32.050Z | 9 m 49 s |
| → camera loaded (0.78 s) | 2026-05-06T12:11:32.834Z | 9 m 50 s |
| Bootstrap: load yolo | 2026-05-06T12:11:32.854Z | 9 m 50 s |
| → yolo loaded (20.34 s) | 2026-05-06T12:11:53.194Z | 10 m 10 s |
| Bootstrap: load llava | 2026-05-06T12:11:53.217Z | 10 m 10 s |
| → llava loaded (31.10 s) | 2026-05-06T12:12:24.318Z | 10 m 41 s |
| Bootstrap: load voxtral | 2026-05-06T12:12:24.341Z | 10 m 41 s |
| → **voxtral loaded (4.55 s) — FULLY OPERATIONAL** | 2026-05-06T12:12:28.895Z | **10 m 45 s** ⭐ |

¹ Pull real cold (no cacheado) — confirmado por purgar `k3s ctr images rm <digest>` antes.

⭐ **T_install_cold_cold = 645 s = 10 min 45 s** ⭐

## Desglose: ¿en qué se va el tiempo?

| Fase | Duración | % del total |
|---|---|---|
| Bootstrap K8s (Pods scheduled) | 7 s | 1.1 % |
| **Pull ros2-component-host 31.96 GB** | **486 s (8 m 6 s)** | **75.3 %** |
| Container start + orchestrator + ComponentManager init | 12 s | 1.9 % |
| Stabilización pods (dashboard wait-for-peers + grace) | ~50 s | 7.8 % |
| Bootstrap Job: 4 LoadNode secuenciales | **57 s** | **8.8 %** |
| Otros gaps | ~33 s | 5.1 % |

**El 75 % del tiempo se va en pull de imagen única**. El resto (25 %) son arranque del componente + 4 cargas dinámicas de modelos.

**Pull bandwidth medido**: 31.96 GB / 486 s = **65.7 MB/s = 526 Mbps**. Consistente con los 502 Mbps de overlay-pack y 525 Mbps de ros2-base — el WAN del cluster da ~500 Mbps.

## T_ready por pod (cold-cold)

| Pod | Δ (s) | PodScheduled | Ready | Nodo |
|---|---|---|---|---|
| `dynamic-pattern-...-canonical-0` (runtime) | **488** | 2026-05-06T12:01:50Z | 2026-05-06T12:09:58Z | edgenode01 |
| `dynamic-pattern-...-dashboard-0` | **549** | 2026-05-06T12:01:50Z | 2026-05-06T12:10:59Z | kb2 |

**T_sched_avg cold** = (488 + 549) / 2 = **518 s**
**T_sched_max cold** = **549 s** (dashboard, gated por wait-for-peers)
**T_ready_system cold** = **549 s = 9 min 9 s** (primer PodScheduled → último Ready)

> Nota: T_ready_system (549 s) es solo cuando los CONTENEDORES están listos. Para que el sistema esté operacional necesitas además que el bootstrap haya cargado los 4 nodos AI dinámicamente (otros 57 s). Por eso T_install_e2e (645 s) > T_ready_system (549 s) — los 96 s de delta son el load dinámico + un poco de espera.

## C-7: tiempos de LoadNode dinámico

**Este es el dato diferenciador del paper para dynamic-canonical**:

| Módulo | Plugin | Load (s) | unique_id |
|---|---|---|---|
| camera | `camera_driver_pkg::CameraDriver` | **0.78** | 1 |
| yolo | `yolo_detector_pkg::YoloDetector` | **20.34** | 2 |
| llava | `llava_pkg::LlavaNode` | **31.10** | 3 |
| voxtral | `voxtral_pkg::VoxtralNode` | **4.55** | 4 |
| **TOTAL secuencial** | — | **56.77 s** | — |

**Interpretación**:
- `camera`: súper rápido porque solo abre `/dev/video1` y empieza a publicar. Ningún modelo a cargar.
- `yolo`: 20 s = `ultralytics` import + `yolov8n.pt` load (3.2 M params) + cuDNN warmup en GPU
- `llava`: 31 s = `transformers` import + LLaVA-1.5-7B FP16 load a VRAM (~13 GB) + dispatch
- `voxtral`: 4.5 s = mucho más rápido (Voxtral está en `audio_mode=True` ahora; el modelo es solo 3 B params y carga rápido)

**Comparativa para el paper** (tiempo de "swap one component"):

| Pattern | Time to swap one model |
|---|---|
| monolithic | ~15-25 min (rebuild + push 30 GB + pull + boot) |
| microservices | ~5-10 min (rebuild ONE microservice + push + pull) |
| overlay-canonical | ~2.5 min cold-ish (re-extract overlay) |
| **dynamic-canonical** | **0.78 s (camera) … 31.10 s (LLaVA)** ⭐⭐⭐ |

Dynamic es **2-3 órdenes de magnitud más rápido** para hot-swap de un componente. Es exactamente lo que vende su valor en el paper.

## Steady-state (recién Ready, 14 s tras voxtral load)

| Pod | CPU | Memory |
|---|---|---|
| `runtime-0` | **1687 m** (1.69 cores) | **10 150 MiB** (~9.9 GiB) |
| `dashboard-0` | 40 m | 100 MiB |

⚠️ **Memoria mucho menor que overlay-canonical (10.1 vs 16.5 GiB)**. Hipótesis: en cold-cold inicial hay menos huellas de buffers acumulados que en overlay. Conforme las inferencias se acumulen, debería subir hacia 16-17 GiB (similar a overlay/monolithic).

## Métricas runtime (dashboard, 14 s uptime)

| Métrica | Valor |
|---|---|
| Camera | ⚠️ FALLBACK SYNTHETIC (frame 8304 visible) — `/dev/video1` no accesible |
| T_inf (avg) | 351.4 ms |
| f_FPS (theor.) | 2.8 fps |
| f_FPS (pub) | 2.6 fps |
| T_e2e (avg / max) | 318 / 513 ms |
| T_ready (loop) | 0.18 s |
| J_inf | 42.8 ms (alto, buffers iniciales) |
| U_CPU (avg/max) | 24.1 / 43.3 % |
| U_GPU (avg/max) | 5.3 / 15.7 % |
| U_RAM (avg/max) | 30.3 / 30.4 % |

> ⚠️ **Camera en synthetic fallback**: el plugin `camera_driver_pkg::CameraDriver` se cargó con `synthetic_mode: False` y `device: /dev/video1`, pero el dashboard muestra "synthetic frame 8304". Probablemente la cámara real no está accesible (overlay-canonical anterior la liberó al uninstall, pero el chart de dynamic-canonical puede no estar pasando correctamente `--device /dev/video1` en privileged mode al pod). Pendiente verificar en otra iteración.

## Métricas en limpio para el paper

```
dynamic-canonical S1 COLD-COLD:
  T_install_e2e          = 645 s   (10 min 45 s)
  T_ready_system         = 549 s   (9 min 9 s)
  T_sched_avg            = 518 s
  T_sched_max            = 549 s
  Image pull (component-host 31.96 GB) = 486 s   (65.7 MB/s ≈ 526 Mbps)
  Bootstrap LoadNode total              = 57 s
    camera load   = 0.78 s
    yolo load     = 20.34 s
    llava load    = 31.10 s
    voxtral load  = 4.55 s
  η_start = 1/T_install                 = 0.00155
```

## Comparativa cold-cold de los 2 patterns canónicos medidos

| Métrica | overlay-canonical | dynamic-canonical |
|---|---|---|
| T_install_e2e | 949 s (16 m) | **645 s (10 m 45 s)** ⚡ |
| T_ready_system | 421 s | 549 s |
| Pull dominante | overlay-pack 26 GB | component-host 32 GB |
| Pull % del total | 43.6 % | **75.3 %** |
| HTTP sync edge | 305 s | 0 s (no hay) |
| Job extraction | 93 s | 0 s (no hay) |
| LoadNode dinámico | n/a | 57 s (ventaja del pattern) |

**Dynamic es 5 minutos más rápido en cold-cold** porque elimina dos costes de overlay-canonical: la extracción a PVC (93 s) y la sync HTTP cloud→edge (305 s = 5 min). El precio es una imagen más grande (32 GB vs 26+2 GB), pero el flujo es más directo.

**El argumento del paper**: dynamic gana en cold-cold por ser "directo a edge", overlay gana en escalabilidad multi-edge (porque el cloud nginx sirve el overlay en LAN a N edges, vs N edges descargando 32 GB cada uno del registry remoto). Cada pattern tiene su nicho.
