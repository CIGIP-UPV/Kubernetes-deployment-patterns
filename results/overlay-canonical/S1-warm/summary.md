# overlay-canonical — S1-warm run summary

_Captured: 2026-05-06 (warm restart tras `helm upgrade --set camera.syntheticMode=false --set camera.device=/dev/video1` + `kubectl delete pod`)_

Release: `over-pattern`  ·  Namespace: `ros2exp`
Escenario: **S1** (FPS=10, cámara real `/dev/video1`)
Tipo de run: **warm restart** (imágenes ya en caché de containerd, PVC del overlay ya provisionada y poblada)

---

## T_ready por pod

| Pod | Δ (s) | PodScheduled | Ready | Nodo |
|---|---|---|---|---|
| `over-pattern-ros2-overlay-canonical-overlay-server-7fd498c9qtd6` | **2** | 2026-05-06T07:36:41Z | 2026-05-06T07:36:43Z | worker1-kb2 |
| `over-pattern-ros2-overlay-canonical-dashboard-0` | **69** | 2026-05-06T07:37:06Z | 2026-05-06T07:38:15Z | kb2 |
| `over-pattern-ros2-overlay-canonical-0` (runtime) | **40** | 2026-05-06T07:38:41Z | 2026-05-06T07:39:21Z | edgenode01 |

**T_ready_system** (primer PodScheduled → último Ready) = **160 s** (~2 min 40 s)

> Nota: este es un warm restart, NO un cold-start. Los pulls de imagen
> reportaron tiempos sub-segundo (`Pulled in 386ms` / `313ms` / `360ms`),
> lo que confirma que las imágenes (ros2-base 2.4 GB, overlay-pack 26.9 GB,
> dashboard 270 MB) ya estaban en containerd. La PVC también se reusó.
> El cold-start auténtico requiere uninstall + delete PVC + purga de
> imágenes en los 3 nodos antes del install.

## Steady-state — `kubectl top pod -n ros2exp` (26 min uptime)

| Pod | CPU | Memory |
|---|---|---|
| `over-pattern-ros2-overlay-canonical-0` (runtime) | **1235 m** (1.24 cores) | **17264 MiB** (~16.9 GiB) |
| `over-pattern-ros2-overlay-canonical-dashboard-0` | 222 m | 112 MiB |
| `over-pattern-ros2-overlay-canonical-overlay-server-7fd498c9qtd6` | 1 m | 13 MiB |

El runtime es el único peso significativo: 17 GiB de VRAM unificada que aloja
LLaVA-1.5-7B FP16 (~13 GB) + buffers de transformers/torch + procesos ROS 2
(camera_driver, yolo_detector, llava_node, voxtral_node, resource_monitor).
Dashboard y overlay-server son casi gratis.

## Image footprint reportado en eventos

| Imagen | Tamaño | Pull desde caché | Nodo destino |
|---|---|---|---|
| `ros2-base:latest` | 2 408 164 773 B (2.24 GiB) | 386 ms | edgenode01 |
| `ros2-overlay-pack:latest` | 26 902 423 020 B (25.05 GiB) | 313 ms | worker1-kb2 (Job) |
| `ros2-dashboard:latest` | 270 402 470 B (258 MiB) | 360 ms | kb2 |
| `nginx:alpine` | (cached) | 0 ms | worker1-kb2 |
| `busybox:1.36`, `alpine:latest` | (cached) | 0 ms | edgenode01 |

S_img total = **27.55 GiB** (2.24 + 25.05 + 0.26)

## Eventos relevantes

- `Job overlay-installer`: pod programado en worker1-kb2, pulled overlay-pack en 313 ms, started container, completed.
- `Deployment overlay-server`: 1/1 replicas, nginx ya cacheado, started en 2 s.
- `StatefulSet runtime`: tras `kubectl delete pod`, el reschedule tomó 35 s adicionales hasta empezar containers (espera del Job overlay-installer + readiness del overlay-server).
- `StatefulSet dashboard`: arrancó en 69 s, dominado por `wait-for-peers` (busybox que espera al runtime).
- Aviso (no bloqueante): `persistentvolumeclaim ... is being deleted` durante el upgrade — el chart elimina y recrea la PVC del overlay incluso para cambios triviales de config. **Coste arquitectural a discutir en el paper**: cambiar un flag de cámara dispara re-extract del tarball.
- Aviso (recovered): `BackOff restarting failed container overlay-runtime` 28 min antes del último restart limpio. Causa probable: cu13 conflict del primer despliegue de la sesión (ya no aparece tras chart 1.0.7+).

## Métricas runtime (dashboard, 26 min uptime — segunda screenshot)

| Métrica | Valor |
|---|---|
| T_inf (avg) | 32.7 ms |
| f_FPS (theor.) | 30.6 fps |
| f_FPS (pub) | 10.2 fps |
| T_e2e (avg) | 6089 ms |
| T_e2e (max) | 59993 ms |
| T_ready (lazo) | 0.12 s |
| J_inf (jitter) | 8.5 ms |
| U_CPU (avg / max) | 21.2 / 45.3 % |
| U_GPU (avg / max) | 51.7 / 99.9 % |
| U_RAM (avg / max) | 33.3 / 33.7 % |
| L_IO (read / write) | 0.12 / 0.03 MB/s |
| P_avg, E_inf, η_energy | No data (Jetson sin tegrastats accesible) |

LLaVA detección estable: "A black office chair is positioned in front of a window..." (latency 12 950 ms / inference 12 925 ms).
YOLO detección estable: 1 chair (73 % confidence), 0 persons.

> **Nota sobre T_e2e (avg) = 6089 ms**: este valor está dominado por el
> auto-trigger LLaVA cada 30 s (cada inferencia añade ~13 s de latencia
> end-to-end). Si se mide solo YOLO, T_e2e baja al rango de 30-60 ms
> como en la primera screenshot. La media incluye ambos pipelines.

## Tamaño extraído del overlay en el edge

| Path | Size |
|------|------|
| /opt/overlay | **34 GB** |

(Los subdirectorios `python-deps` y `huggingface_cache` no devolvieron
output — probablemente nombres distintos en el filesystem real. Habría
que entrar al pod con `kubectl exec` para verificar.)

## Lo que falta capturar para el paper

- [ ] Cold-start auténtico (S1-cold) tras purgar imágenes y PVC
- [ ] S2 (FPS=20) → cambiar `camera.fps=20` por Rancher Edit + `kubectl delete pod`
- [ ] S3 (FPS=30) → cambiar `camera.fps=30` por Rancher Edit + `kubectl delete pod`
- [ ] Desglose de `/opt/overlay/{python-deps,huggingface_cache,install}` (necesita `ls /opt/overlay` para descubrir nombres reales)
- [ ] Screenshot del dashboard guardada como `dashboard.png` en esta carpeta
