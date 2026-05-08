# overlay-canonical — S1-cold run summary

_Captured: 2026-05-06 (uninstall + delete PVC + reinstall desde Rancher GUI)_

Release: `over-pattern`  ·  Namespace: `ros2exp`
Escenario: **S1** (FPS=10, cámara real `/dev/video1`)
Tipo de run: **cold-ish start** (PVC borrada, pero imágenes containerd cacheadas y hostPath edge persistente)

## T_install end-to-end (lo que importa para el paper)

| Marca | Timestamp | Δ desde T_zero |
|---|---|---|
| **T_zero** (`date` antes de install) | 2026-05-06T08:26:12Z | 0 s |
| Job overlay-installer creado | 2026-05-06T08:26:11Z | -1 s ¹ |
| PVC provisionada | 2026-05-06T08:26:14Z | 2 s |
| overlay-installer container started | 2026-05-06T08:26:16Z | 4 s |
| Job overlay-installer completed | 2026-05-06T08:27:29Z | **77 s** |
| StatefulSets/Deployment scaled up | 2026-05-06T08:27:29Z | 77 s |
| Todos los Pods PodScheduled | 2026-05-06T08:27:40Z | **88 s** |
| overlay-server Ready | 2026-05-06T08:27:43Z | 91 s |
| runtime-0 Ready | 2026-05-06T08:28:30Z | 138 s |
| dashboard-0 Ready | 2026-05-06T08:28:43Z | **151 s** ⭐ |
| T_fin (`date` tras kubectl wait) | 2026-05-06T08:32:16Z | 364 s ² |

¹ Diferencia de 1 s probablemente reloj de la shell vs reloj del API server.

² Los 364 s del `date` final incluyen tiempo "extra" después de que todos los pods estuvieran Ready: probablemente kubectl wait verificó pero ella copió los timestamps con calma. **El dato real es 151 s** (medido desde conditions del API server).

⭐ **T_install_cold = 151 s = 2 min 31 s**

## T_ready por pod (cold)

| Pod | Δ (s) | PodScheduled | Ready | Nodo |
|---|---|---|---|---|
| `over-pattern-...-overlay-server-7fd498ctrjxm` | **3** | 2026-05-06T08:27:40Z | 2026-05-06T08:27:43Z | worker1-kb2 |
| `over-pattern-...-canonical-0` (runtime) | **50** | 2026-05-06T08:27:40Z | 2026-05-06T08:28:30Z | edgenode01 |
| `over-pattern-...-dashboard-0` | **63** | 2026-05-06T08:27:40Z | 2026-05-06T08:28:43Z | kb2 |

**T_sched_avg cold** = (3 + 50 + 63) / 3 = **38.7 s**
**T_sched_max cold** = **63 s** (dashboard, gated por wait-for-peers)
**T_ready_system cold** (primer PodScheduled → último Ready) = **63 s**

## Comparación cold vs warm

| Métrica | S1-warm | S1-cold | Δ |
|---|---|---|---|
| T_ready_system (primer Sched → último Ready) | 160 s | 63 s | **−97 s (−61%)** |
| T_sched runtime | 40 s | 50 s | +10 s |
| T_sched dashboard | 69 s | 63 s | −6 s |
| T_sched overlay-server | 2 s | 3 s | +1 s |
| T_install end-to-end | n/a | **151 s** | (no medible en warm) |
| Job overlay-installer | n/a (re-extrajo igual) | **77 s** | (visible en cold) |

**Observación importante**: el cold-ish ES más rápido a nivel de T_ready_system que el warm restart, **pero solo porque el helm upgrade del warm hizo un rolling update secuencial** (overlay-server primero, dashboard 25 s después, runtime 95 s después de dashboard). En cold, los 3 pods se programan **en paralelo** porque es helm install, no upgrade. La parallelización gana 2 min al T_ready_system.

El número honesto del cold-start completo es **T_install = 151 s**, que incluye los 77 s del Job de extracción del overlay tarball + 74 s de bootstrap de pods.

## Steady-state (cold, recién Ready)

| Pod | CPU | Memory |
|---|---|---|
| `runtime-0` | 1395 m | 16 617 MiB (~16.2 GiB) |
| `dashboard-0` | 219 m | 111 MiB |
| `overlay-server-...` | 1 m | 14 MiB |

Diferencia con S1-warm a 26 min: runtime arranca con 16.2 GiB (acaba de cargar LLaVA en VRAM), warm a 26 min reportaba 16.9 GiB (ligeras fugas de buffers de inferencias acumuladas, normal).

## Timeline anotado (cold)

```
T+0    s   helm install (botón Install en Rancher)
T+0    s   Helm crea Namespace, ConfigMaps, ServiceAccounts, PVC, Job, StatefulSets, Service
T+2    s   PVC provisionada (rancher.io/local-path es local-disk, instantáneo)
T+4    s   Job pod scheduled en worker1-kb2; overlay-pack image pull (256 ms, cached)
T+6    s   overlay-installer ejecuta cp -a /opt/overlay → /pvc/overlay (17 GB)
T+77   s   Job completed
T+77   s   StatefulSets escalonan a 1 replica
T+88   s   Pods PodScheduled (overlay-server, runtime, dashboard en paralelo)
T+91   s   overlay-server Ready (nginx serve PVC, listo en 3 s)
T+88   s   runtime: wait-for-services init (espera DNS de overlay-server)
T+95   s   runtime: overlay-sync init (HTTP GET → /opt/overlay; 7 s porque hostPath persistente)
T+98   s   runtime: ros2-base pull (370 ms cached)
T+100  s   runtime: overlay-runtime container started
T+138  s   runtime Ready (38 s de bootstrap ROS 2 + carga de modelos)
T+88   s   dashboard: wait-for-peers init (espera runtime DNS)
T+143  s   dashboard: ros2-dashboard pull (379 ms cached) + container started
T+151  s   dashboard Ready ✓ TODO READY
```

## Lo que NO se midió en este cold-ish y costaría en un cold-cold

| Coste oculto | Tiempo estimado si fuese cold-cold |
|---|---|
| Pull overlay-pack 26 GB sobre LAN (no cached) | +5-10 min |
| Pull ros2-base 2.4 GB sobre LAN (no cached) | +1-2 min |
| Pull ros2-dashboard 270 MB | +20 s |
| HTTP sync overlay 17 GB cloud→edge (hostPath limpia) | +5-10 min |
| **Cold-cold T_install estimado** | **15-25 min** |

El cold-ish (151 s) ≈ "OTA con registry mirror local + edge cache previa".
El cold-cold (15-25 min) ≈ "primera publicación absoluta del cluster".

Para el paper, ambos números son útiles según el escenario que cuentes.

## Métricas en limpio para el paper

```
overlay-canonical S1 cold-ish (registry mirror cached, edge hostPath persisted):
  T_install               = 151 s
  T_sched_avg             = 38.7 s
  T_sched_max             = 63 s (dashboard)
  T_ready_system          = 63 s
  Job extraction (PVC)    = 77 s
  HTTP sync edge          = ~7 s (skipped, hostPath warm)
  Image pulls             = ~1 s sumado (todas cached)
  η_start = 1/(T_install) = 0.00662
```
