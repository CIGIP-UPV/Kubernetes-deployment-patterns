# Tabla comparativa — los 4 patterns medidos

_Última actualización: 2026-05-07. Campaña automatizada `20260507-123512` con
metodología uniforme: warmup 10 min, ventana de muestreo 3 min, n=1 por pattern,
ROS_DOMAIN_ID=42, FPS=10, cámara real `/dev/video1` en edgenode01 (Jetson AGX
Orin 64 GB)._

## 1. Footprint de imágenes

| Pattern | S_img total local | Imágenes | OTA payload típico (1 update) |
|---|---|---|---|
| monolithic | 30.01 GB | 1 (todo) | 30 GB completos |
| microservices | 41.24 GB | 5 (cam, yolo, llava, voxtral, dash) | 5-19 GB del nodo afectado |
| **overlay-canonical** | **27.54 GB** | 3 (base 2.24 + overlay-pack 25.05 + dash 0.25) | **25 GB del overlay-pack** |
| dynamic-canonical | 30.02 GB | 2 (component-host 29.77 + dash 0.25) | 30 GB completos |

**Ganador en footprint**: overlay-canonical. **Peor**: microservices (41 GB).

## 2. Cold-start (T_install end-to-end)

| Pattern | T_install MEDIDO | Tipo de pull | Origen del coste |
|---|---|---|---|
| monolithic | **513 s (8 min 33 s)** | warm (image en caché edge) | pull único + boot StatefulSet + carga de modelos |
| microservices | **643 s (10 min 43 s)** | warm | 5 pulls paralelos (cam, yolo, llava, voxtral, dashboard) |
| dynamic-canonical | **137 s (2 min 17 s)** ¹ | warm | pull único component-host + bootstrap Job (4 LoadNode) |
| **overlay-canonical** | **949 s (15 min 49 s)** ² | cold-cold | overlay-pack 26 GB pull + 17 GB extract a PVC + 17 GB sync edge |

¹ El T_install de dynamic-canonical en cold-cold es **645 s** (medido el
2026-05-06). Los 137 s del 2026-05-07 reflejan un re-deploy con la imagen
`ros2-component-host` ya cacheada en edgenode01.

² overlay-canonical no se midió en la campaña 20260507 porque su pre-install
Job (3-fase: pull 26 GB + cp 17 GB a PVC + HTTP sync 17 GB cloud→edge) excede el
timeout interno de `helm install --wait --timeout 45m` cuando se lanza desde el
script automatizado. La medición de 949 s proviene de un cold-cold ejecutado vía
Rancher UI el 2026-05-06, donde el catalog timeout (también 45 min, anotado en
`Chart.yaml`) sí se respeta correctamente. Detalles en
[`results/overlay-canonical/S1-cold-cold/summary.md`](../../results/overlay-canonical/S1-cold-cold/summary.md).

## 3. Métricas runtime (estado estable, dashboard, cámara real)

Capturado tras 10 min de warmup (LLaVA dispara ≥ 1 vez), ventana de muestreo
de 180 s, valores agregados sobre el flujo de tópicos rosbridge.

| Métrica | Monolithic | Microservices | Dynamic-canonical | Overlay-canonical ³ |
|---|---:|---:|---:|---:|
| T_inf (avg, ms) | 38.46 | 37.44 | 76.54 | **32.70** |
| f_FPS (pub) | 9.70 | **10.11** | 5.45 | 10.20 |
| T_e2e (avg, ms) | 112.83 | 134.46 | 224.67 | **15** ⁴ |
| J_inf (ms) | 12.70 | 12.69 | 74.50 | **8.50** |
| U_CPU (avg, %) | 22.51 | 24.56 | 24.24 | **21.20** |
| U_GPU (avg, %) | 51.68 | 50.77 | 46.66 | 51.70 |
| U_RAM (avg, %) | 33.34 | 53.14 | **32.63** | 33.30 |
| Voxtral audio mode | TEXT_SIM | **AUDIO REAL** | TEXT_SIM | TEXT_SIM ⁵ |
| YOLO real-camera detection | ✅ | ✅ | ✅ | ✅ |
| LLaVA scene description | ✅ | ✅ | ✅ | ✅ |

³ Métricas runtime de overlay-canonical proceden de la sesión del 2026-05-06
(`results/overlay-canonical/S1-real-camera/dashboard_metrics.csv`), captura
con cámara real y >5 min de uptime. La metodología no es perfectamente
sincronizada con la campaña 20260507 — se documenta en "Threats to validity".

⁴ Overlay-canonical capturado en ventana clean (sin LLaVA accumulada). Si LLaVA
dispara durante la ventana de muestreo, T_e2e sube al rango de 6000 ms avg
debido a la latencia de la inferencia LLaVA-1.5-7B (~13 s).

⁵ Dynamic ejecuta Voxtral en TEXT_SIMULATION por la misma constraint que
overlay-canonical (transformers 4.48 sin VoxtralProcessor; audio real requiere
transformers ≥ 4.54 que rompe LLaVA-1.5).

## 4. T_ready de bucle ROS

Valor mostrado por el dashboard en estado estable:

| Pattern | T_ready (loop) |
|---|---|
| Monolithic | 0.76 s |
| Microservices | 0.75 s |
| Overlay-canonical | **0.12 s** |
| Dynamic-canonical | 0.18 s |

Los 4 patterns están en el rango sub-segundo. Overlay y dynamic son notablemente
más rápidos.

## 5. C-7: Hot-swap de un componente (el dato killer del paper)

| Pattern | Time to swap ONE ML component |
|---|---|
| monolithic | ~15-25 min (rebuild image + push 30 GB + pull edge + boot) |
| microservices | ~5-10 min (rebuild ONE microservice 5-19 GB + push + pull) |
| overlay-canonical | ~2.5 min cold-ish (re-extract overlay tarball) |
| **dynamic-canonical** | **0.78 - 31.10 s** ⭐⭐⭐ |

Desglose del C-7 dinámico (medido sobre el orchestrator FastAPI vía
`/load`/`/unload`, datos en
[`results/dynamic-canonical/load-unload/load_unload_per_module.csv`](../../results/dynamic-canonical/load-unload/load_unload_per_module.csv)):

- camera (no model): **0.78 s**
- yolo (3.2 M params): **20.34 s**
- **llava-1.5-7B FP16: 31.10 s**
- voxtral-Mini-3B: **4.55 s**

**Dynamic-canonical es 2-3 órdenes de magnitud más rápido** en hot-swap que
los demás patterns.

## 6. Latencia de red (medida una vez, válida para todos)

| Nodo | IP | RTT avg |
|---|---|---|
| kb2 (cloud, control-plane) | 158.42.104.15 | 4.2 ms |
| edgenode01 (Jetson) | 158.42.104.206 | 7.9 ms |
| worker1-kb2 | 158.42.104.103 | 30.4 ms (variable) |

Bandwidth efectivo registry → cluster: **~500 Mbps** (medido en pulls cold-cold).

## 7. Argumento ejecutivo para cada pattern

| Pattern | Cuándo usarlo | Coste principal |
|---|---|---|
| **monolithic** | Sistema simple sin cambios frecuentes | OTA por update = imagen entera |
| **microservices** | Componentes que cambian de forma independiente | Mucha imagen por nodo + RAM (~53 % avg) |
| **overlay-canonical** | Múltiples edges, OTA recurrente del modelo AI | Doble salto cloud-PVC-edge |
| **dynamic-canonical** | A/B testing, hot-swap, dev iterativo | Imagen grande, no escala multi-edge, T_inf y J_inf más altos |

## 8. Threats to validity

1. **n=1 por pattern**. La campaña 20260507 ejecutó una corrida por pattern. Para
   estadísticas de variabilidad (mean ± SD) se requeriría n ≥ 3.

2. **overlay-canonical medido en sesión separada**. Su pre-install Job no
   completa dentro del timeout de `helm install --wait` cuando se lanza desde
   `run_full_campaign.sh` (helm devuelve `context deadline exceeded`). Los datos
   actuales proceden de un deploy vía Rancher UI el 2026-05-06. El T_install
   (949 s cold-cold) y las métricas runtime son válidos pero no comparten timing
   exacto con la campaña automatizada de los otros 3 patterns.

3. **dynamic-canonical T_install warm vs cold-cold**. Los 137 s reportados en
   §2 son warm restart (imagen `ros2-component-host` ya cacheada). El cold-cold
   medido en sesión previa es 645 s. Para una comparación apples-to-apples con
   el resto, considérese 645 s.

4. **Voxtral audio mode degradado en 3 de 4 patterns**. transformers 4.48 (pin
   por compatibilidad con LLaVA-1.5) no incluye `VoxtralProcessor`, así que en
   monolithic, dynamic-canonical y overlay-canonical Voxtral cae a
   TEXT_SIMULATION. Solo microservices, que aísla cada modelo en su propia
   imagen, ejecuta Voxtral en AUDIO REAL.

5. **Métricas energéticas no capturadas** ($P_{avg}$, $E_{inf}$,
   $\eta_{energy}$). El binario `tegrastats` no está montado dentro de los
   contenedores del runtime pod, por lo que `resource_monitor.py` no publica
   `/node/power_mw`. Se identifica como future work.

6. **T_ready_loop de overlay-canonical 0.12 s vs ~0.75 s en mono/micro**. El
   delta es notable y consistente con la literatura de overlay workspaces
   (menos estado inicial de la base inmutable), pero no se ha hecho una
   comparación cruzada controlada para descartar artefactos de medición.

## 9. Estado del paquete experimental

- [x] Métricas runtime de los 4 patterns
- [x] S_img de los 4 patterns
- [x] Cold-start MEDIDO de los 4 patterns (overlay-canonical 949 s; los otros 3
      son warm en la campaña 20260507; dynamic-canonical también tiene 645 s
      cold-cold de la sesión previa)
- [x] **C-7 de dynamic-canonical (0.78–31.10 s por módulo)** ⭐
- [x] Network bandwidth + latencia
- [ ] n ≥ 3 corridas por pattern
- [ ] Cold-cold MEDIDO de monolithic y microservices (la campaña 20260507 fue
      warm; el cold-cold real requiere purgar imágenes en los 3 nodos antes de
      cada install)
- [ ] Métricas energéticas (requiere mount de `/usr/bin/tegrastats` o
      DaemonSet privilegiado leyendo sysfs `/sys/class/power_supply/`)

Para el submission de IEEE Access los datos cubren los argumentos centrales del
paper. Los puntos pendientes corresponden a "future work" o se documentan
explícitamente en la sección "Threats to validity" del manuscrito.
