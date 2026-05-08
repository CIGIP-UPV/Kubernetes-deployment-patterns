# overlay-canonical — S1-cold-cold run summary

_Captured: 2026-05-06T09:04:29Z (helm uninstall + delete PVC + purge containerd images en los 3 nodos + clean hostPath edge + reinstall desde Rancher GUI)_

Release: `over-pattern`  ·  Namespace: `ros2exp`
Escenario: **S1** (FPS=10, cámara real `/dev/video1`)
Tipo de run: **cold-cold (TRUE COLD START)** — imágenes Docker purgadas (`k3s ctr images rm` + `crictl rmi --prune`), PVC borrada, hostPath `/mnt/ssd/overlay-canonical-runtime` limpia.

## Timeline anotado

| Marca | Timestamp | Δ desde T_zero |
|---|---|---|
| **T_zero** (`date` antes de Install) | 2026-05-06T08:48:40Z | 0 s |
| Job overlay-installer creado | 2026-05-06T08:49:29Z | 49 s |
| PVC provisionada | 2026-05-06T08:49:32Z | ~52 s |
| **Pull overlay-pack 26 GB completado** | 2026-05-06T08:55:35Z | ~6 m 55 s ¹ |
| Job overlay-installer completed (cp 17 GB → PVC) | 2026-05-06T08:57:08Z | ~8 m 28 s |
| Pods PodScheduled (overlay-server, runtime, dashboard) | 2026-05-06T08:57:20Z | **8 m 40 s** |
| overlay-server Ready (nginx pull 4 s) | 2026-05-06T08:57:26Z | 8 m 46 s |
| dashboard Ready (peer-grace 60 s) | 2026-05-06T08:58:28Z | 9 m 48 s |
| HTTP sync 17 GB cloud → edge completado | 2026-05-06T09:02:43Z | ~14 m 3 s ² |
| **Pull ros2-base 2.4 GB completado** | 2026-05-06T09:03:36Z | ~14 m 56 s ¹ |
| overlay-runtime container started | 2026-05-06T09:03:38Z | ~14 m 58 s |
| **runtime Ready** (carga LLaVA + arranque ROS 2) | 2026-05-06T09:04:21Z | **15 m 41 s** ⭐ |
| T_fin (`date` tras kubectl wait) | 2026-05-06T09:04:29Z | 15 m 49 s |

¹ Pulls reales no cacheados — la prueba de que purgamos bien.
² El overlay-sync init container hizo el HTTP GET de 17 GB completo porque borramos `/mnt/ssd/overlay-canonical-runtime`.

⭐ **T_install_cold_cold = 949 s ≈ 15 min 49 s** ⭐

## Desglose: ¿en qué se va el tiempo?

| Fase | Duración | % del total | Quién lo paga |
|---|---|---|---|
| Bootstrap Job + PVC provision | ~52 s | 5.5 % | Kubernetes / k3s |
| **Pull overlay-pack 26 GB** | **6 m 55 s (414 s)** | **43.6 %** | Network registry → worker1-kb2 |
| Job extract 17 GB cp → PVC | ~93 s | 9.8 % | Disk I/O en worker1-kb2 |
| Schedule pods + overlay-server up | ~12 s | 1.3 % | Kubernetes |
| **HTTP sync 17 GB cloud → edge** | **~5 m 5 s (305 s)** | **32.1 %** | Network LAN nginx → edge hostPath |
| Pull ros2-base 2.4 GB | 53 s | 5.6 % | Network registry → edgenode01 |
| Container start + LLaVA FP16 load | ~43 s | 4.5 % | Disk + GPU on edge |

**Conclusión arquitectural**: el 75% del cold-start se va en transferencias de red (414 + 305 = 719 s). De esos 12 minutos de red:
- 6m 55s pulling 26 GB del registry GitLab (datacenter) a worker1-kb2 (cloud) — ~63 MB/s ≈ 500 Mbps
- 5m 5s syncing 17 GB de cloud nginx a edge hostPath — ~52 MB/s ≈ 415 Mbps

El bandwidth efectivo de 400-500 Mbps es coherente con LAN de 1 Gbps con overhead.

## T_ready por pod (cold-cold)

| Pod | Δ (s) | PodScheduled | Ready | Nodo |
|---|---|---|---|---|
| `over-pattern-...-overlay-server-7fd498c8thsl` | **6** | 2026-05-06T08:57:20Z | 2026-05-06T08:57:26Z | worker1-kb2 |
| `over-pattern-...-dashboard-0` | **68** | 2026-05-06T08:57:20Z | 2026-05-06T08:58:28Z | kb2 |
| `over-pattern-...-canonical-0` (runtime) | **421** | 2026-05-06T08:57:20Z | 2026-05-06T09:04:21Z | edgenode01 |

**T_sched_avg cold-cold** = (6 + 68 + 421) / 3 = **165 s**
**T_sched_max cold-cold** = **421 s** (runtime, gated por HTTP sync 17 GB + ros2-base pull + LLaVA load)
**T_ready_system cold-cold** = **421 s = 7 min 1 s** (primer PodScheduled → último Ready)

> Nota: dashboard Ready a 08:58:28 (T+68 s desde su PodScheduled) sucedió **antes** que runtime Ready, porque el dashboard solo espera a que el Service del runtime resuelva DNS (lo cual ocurre nada más crear el Pod), no a que el runtime esté Ready. El `peerReadyGraceSeconds=60` de la chart explica los 60 s de espera del dashboard.

## Comparación warm / cold-ish / cold-cold

| Métrica | warm | cold-ish | **cold-cold** |
|---|---|---|---|
| T_install end-to-end | 160 s ³ | 151 s | **949 s** |
| T_ready_system | 160 s | 63 s | 421 s |
| T_sched_max | 69 s | 63 s | 421 s |
| Pull overlay-pack | cached (313 ms) | cached (257 ms) | **6 m 55 s** ⭐ |
| Pull ros2-base | cached (386 ms) | cached (370 ms) | **53 s** ⭐ |
| HTTP sync 17 GB edge | skipped (hostPath persisted) | skipped (hostPath persisted) | **~5 min** ⭐ |
| Job extract 17 GB → PVC | ~80 s | ~77 s | ~93 s |

³ Para warm es upgrade rolling, no install desde cero — los 160 s incluyen stagger de pods que en install desde cero ocurre en paralelo.

## Steady-state cold-cold (recién Ready)

| Pod | CPU | Memory |
|---|---|---|
| `runtime-0` | **1804 m** (1.80 cores) | 16 504 MiB (~16.1 GiB) |
| `dashboard-0` | 50 m | 100 MiB |
| `overlay-server-...` | 1 m | 44 MiB |

CPU del runtime alto (1804 m) probablemente porque LLaVA acaba de hacer inferencia inicial y/o ROS 2 está arrancando todos los publishers. Se estabiliza a los pocos minutos.

## Métricas en limpio para el paper

```
overlay-canonical S1 COLD-COLD (purged containerd + clean hostPath):
  T_install_e2e          = 949 s   (15 min 49 s)
  T_ready_system         = 421 s   (7 min 1 s)
  T_sched_avg            = 165 s
  T_sched_max            = 421 s   (runtime, gated by HTTP sync + LLaVA load)
  Image pull overlay-pack = 414 s  (26 GB → 62.8 MB/s)
  Image pull ros2-base    = 53 s   (2.4 GB → 44.9 MB/s)
  Job extract → PVC       = 93 s   (17 GB cp on worker1-kb2)
  HTTP sync cloud → edge  = 305 s  (17 GB → 51.5 MB/s)
  Container + LLaVA load  = 43 s
  η_start = 1/T_install   = 0.00105
```

## Lo que cuenta para el paper

**El argumento central**: en overlay-canonical, **el coste OTA por publicación de un nuevo modelo es 25 GB del overlay-pack**, NO los 30+ GB de monolithic. Y de esos 25 GB:
- Solo se transfiere UNA VEZ del registry al cluster (worker1-kb2)
- Y se replica internamente por LAN al edge (más rápido que internet)
- Si tienes muchos edges, **no escala el coste de OTA** porque los edges descargan del cloud nginx local, no del registry remoto

**El argumento secundario**: para una sola edge, T_install_cold_cold ≈ 16 min, dominado por transferencias de red. Pero un cambio de configuración (warm) son 2-3 min. Y un re-deploy con cache (cold-ish) son ~2 min 30 s.

**El argumento de comparación**: monolithic en cold-cold sería estimado ~30-40 min porque el pull de 30 GB es similar al de overlay-pack pero CADA edge tiene que pullarlo del registry remoto (no hay nginx local). En overlay-canonical solo el cloud worker pulla, y los edges lo reciben por LAN. **Diferencia arquitectural fuerte**.

## Tres bandwidths efectivos medidos

| Tramo | GB | s | MB/s | Mbps |
|---|---|---|---|---|
| GitLab registry → worker1-kb2 (overlay-pack) | 26.0 | 414 | 62.8 | 502 |
| GitLab registry → edgenode01 (ros2-base) | 2.4 | 53 | 44.9 | 359 |
| nginx (worker1-kb2) → edgenode01 (overlay tar) | 17.0 | 305 | 51.5 | 412 |

Los tres en el rango 360-500 Mbps, consistente con LAN 1 Gbps con overhead. **No es throttling**, es ancho de banda real del cluster.
