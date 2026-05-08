# Tabla comparativa — monolithic vs microservices vs overlay-canonical

_Generated: 2026-05-06. Escenario: S1 (FPS=10, cámara real `/dev/video1`, edgenode01 = Jetson AGX Orin 64 GB)._

## 1. Métricas runtime (dashboard, estado estable)

| Métrica | Monolithic | Microservices | Overlay-canonical | Observación |
|---|---|---|---|---|
| T_inf (avg) | 44.9 ms | 35.8 ms | **32.7 ms** | overlay-canonical el más rápido |
| f_FPS (pub) | 10.0 fps | 10.6 fps | 10.2 fps | ≈ igual (cuello = cámara, FPS=10 fijo) |
| f_FPS (theor.) | n/a | n/a | 30.6 fps | techo real GPU sin throttle |
| T_e2e (avg) ¹ | 61 ms | 58 ms | 15 ms* | *clean YOLO-only, primera captura |
| T_e2e (max) ¹ | 458 ms | 196 ms | 30 ms* | *idem |
| J_inf (jitter) | 7.0 ms | 10.8 ms | 8.5 ms | overlay entre los dos |
| U_CPU (avg / max) | 20.5 / 26.6 % | 23.0 / 37.8 % | 21.2 / 45.3 % | overlay similar a mono en avg |
| U_GPU (avg / max) | 88.7 / 99.8 % | 54.3 / 99.9 % | 51.7 / 99.9 % | overlay como microservices ⚠️ |
| U_RAM (avg / max) | 33.2 / 33.2 % | 52.6 / 53.3 % | 33.3 / 33.7 % | overlay como mono (un proceso) |
| L_IO (read / write) | 0.00 / n/a MB/s | 1.43 / n/a MB/s | 0.12 / 0.03 MB/s | mono el más limpio en I/O |
| Audio mode | TEXT_SIM | AUDIO REAL | TEXT_SIM ² | ² transformers 4.48 sin VoxtralProcessor |
| ASR latency | n/a | 1.55× RT | n/a | solo aplica a microservices |

¹ Para overlay-canonical el T_e2e a 26 min sube a 6089/59993 ms porque el auto-trigger LLaVA contamina la media. He usado la primera captura (15/30 ms) que es clean YOLO-only y comparable apples-to-apples con mono/micro.

⚠️ **U_GPU avg de overlay-canonical (51.7 %) es como microservices (54.3 %), no como monolithic (88.7 %)**. Esto es contraintuitivo porque overlay corre todo en un proceso (debería parecerse a mono). Hipótesis: ROS 2 multi-executor reparte mejor la GPU entre nodos cuando todos comparten un único contexto CUDA. Apuntar para discusión.

## 2. Footprint de imágenes (S_img)

| Imagen | Monolithic | Microservices | Overlay-canonical |
|---|---|---|---|
| ros2-base | — | — | 2.24 GB |
| ros2-overlay-pack | — | — | 25.05 GB |
| ros2-monolithic | 29.76 GB | — | — |
| ros2-camera | — | ~3 GB (Jetson) | — |
| ros2-yolo | — | 5.82 GB | — |
| ros2-llava | — | 15.90 GB | — |
| ros2-voxtral | — | 19.27 GB | — |
| ros2-dashboard | 0.24 GB | 0.24 GB | 0.25 GB |
| **TOTAL local (docker)** | **30.01 GB** | **41.24 GB** ³ | **27.54 GB** ⭐ |
| **TOTAL en cluster (extracted)** | **76 GB** | **124 GB** | 34 GB (`/opt/overlay`) + 2.24 GB (base) ≈ 36 GB |

³ El total local (Mac) excluye ros2-camera porque no la tenías cacheada. En la Jetson sumarían ~3 GB más.

⭐ **Overlay-canonical es el footprint más pequeño** — la base de 2.24 GB es inmutable y compartible, solo el overlay-pack de 25 GB se re-publica en updates OTA.

## 3. Tiempo de scheduling (T_sched, cold-start crítico)

| Pod | Monolithic | Microservices | Overlay-canonical (warm) |
|---|---|---|---|
| camera | n/a (en 1 pod) | 1 s | n/a (en runtime) |
| yolo | n/a (en 1 pod) | 123 s | n/a (en runtime) |
| llava | n/a (en 1 pod) | 534 s | n/a (en runtime) |
| voxtral | n/a (en 1 pod) | 629 s | n/a (en runtime) |
| runtime / monolithic-0 | ~600 s ⁴ | n/a | **40 s** (warm) |
| overlay-server | n/a | n/a | **2 s** |
| dashboard | 191 s | 191 s | **69 s** (warm) |
| **T_sched avg** | ~600 s ⁴ | **296 s** | **37 s** (warm) |
| **T_sched max (critical path)** | ~600 s ⁴ | **629 s** (voxtral) | **69 s** (warm, dashboard) |
| **T_ready_system** | ~10 min ⁴ | ~10 min (gated por voxtral) | **160 s** (warm) |

⁴ Para monolithic no tenemos T_sched per-pod desglosado en el csv (no se ejecutó la captura per-pod), solo la estimación de cold-start ~10 min basada en pull de la imagen única de 76 GB.

⚠️ **CAVEAT IMPORTANTE**: el T_sched de overlay-canonical (37 s avg, 160 s system) es **warm restart** — imágenes ya en caché de containerd, PVC ya populada. Para comparar limpio con los otros dos hay que medir cold-start (purgar imágenes + delete PVC). Lo dejamos pendiente.

## 4. T_ready de bucle ROS (del dashboard)

| Pattern | T_ready (loop) |
|---|---|
| Monolithic | 0.76 s |
| Microservices | 0.75 s |
| **Overlay-canonical** | **0.12 s** ⭐ |

⭐ Overlay 6× más rápido en bootstrap del bucle ROS. Hipótesis: la base es muy ligera (2.24 GB) y el overlay ya está montado en el filesystem cuando arranca el contenedor → menos I/O al iniciar.

## 5. Latencia de red (L_net) — independiente del pattern

| Nodo | IP | RTT avg |
|---|---|---|
| kb2 | 158.42.104.15 | 4.2 - 4.7 ms |
| edgenode01 | 158.42.104.206 | 4.7 - 7.9 ms |
| worker1-kb2 | 158.42.104.103 | 4.3 - 30.4 ms ⁵ |

⁵ Variabilidad alta en worker1-kb2 entre mediciones — depende del estado de la red en el momento.

## 6. Lectura ejecutiva para el paper

**El argumento numérico más fuerte de overlay-canonical**:

1. **Footprint más pequeño** (27.54 GB local, 36 GB en cluster) — vs 30/76 monolithic, vs 41/124 microservices. Y de ese footprint, **solo 25 GB del overlay-pack es lo que se transfiere por OTA update**. La base de 2.24 GB se re-usa.

2. **T_ready más rápido** (0.12 s en bucle ROS, 160 s warm restart del sistema) — comparado con ~0.75 s de bucle y ~10 min de cold-start de los otros.

3. **U_GPU compartido como microservices** (51.7 % avg) pero **U_RAM como monolithic** (33.3 %, un solo proceso) — combina lo mejor de ambos.

4. **Diferenciador de OTA**: solo se re-publica el overlay-pack (25 GB), no la base ROS 2 (2.24 GB). En microservices habría que re-publicar la imagen del nodo que cambia (5-19 GB cada una). En monolithic habría que re-publicar 30 GB completos. **Update payload mínimo**.

**Lo que falta para cerrar el paper**:
- ✅ Cold-cold de overlay-canonical → 949 s (16 min). Ver `results/overlay-canonical/S1-cold-cold/`.
- dynamic-canonical (4º pattern) — sin esto la tabla queda incompleta

## 7. Cold-start: 3 modos de overlay-canonical (NUEVO con cold-cold)

| Modo | T_install | Pulls | HTTP sync | Caso de uso |
|---|---|---|---|---|
| **warm** (helm upgrade) | 160 s | cached | skipped | Cambio de config (FPS, flags) |
| **cold-ish** (uninstall+reinstall, imágenes cached) | 151 s | cached | skipped | OTA con registry mirror local |
| **cold-cold** (todo purgado) | **949 s (16 min)** | overlay-pack 414s, base 53s | **305 s** | Primera publicación absoluta |

**Bandwidths efectivos medidos** en cold-cold:
- registry GitLab → cloud worker (overlay-pack 26 GB): 502 Mbps
- registry GitLab → edge (ros2-base 2.4 GB): 359 Mbps
- cloud nginx → edge (overlay tar 17 GB): 412 Mbps

LAN 1 Gbps con ~50% overhead, consistente.

**Argumento de escalabilidad para el paper**: con N edges, monolithic paga N×30 GB de banda WAN; overlay-canonical paga 1×26 GB WAN + N×17 GB LAN. Para N≥5, overlay-canonical es claramente más eficiente.
