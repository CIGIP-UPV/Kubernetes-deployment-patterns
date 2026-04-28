# Plan de implementación: Patrones D (Overlay) y C (Dynamic Loading) canónicos

**Fecha de redacción**: 2026-04-27
**Autora del proyecto**: Laura Moya / Miguel Ángel Mateo Casali (CIGIP-UPV)
**Propósito**: Documento de referencia para que el desarrollo de los Patrones D y C
canónicos se pueda retomar exactamente donde quedó si se pierde contexto.
Captura **decisiones, justificaciones y desviaciones reconocidas** respecto a la teoría
del paper.

---

## 0. Contexto

El proyecto evalúa cuatro patrones de despliegue ROS 2 sobre Kubernetes para
cargas robóticas con AI/ML en Jetson AGX Orin. Tras revisar la implementación
actual contra la teoría del paper "*Deployment Patterns in ROS 2 Cloud-Edge Systems*",
se identificaron desviaciones significativas en los patrones C (Dynamic Module
Loading) y D (Overlay Workspaces).

Decisión tomada el 2026-04-27: ir por el "Camino 2" — re-implementar C y D para
que coincidan con el patrón canónico descrito en el paper, en lugar de relajar el
texto del paper para que coincida con la implementación actual.

A NO confundir: **A (Monolithic)** y **B (Microservices)** ya están alineados con la
teoría y no se tocan.

---

## 1. Estado de los cuatro patrones

| Patrón | Estado teórico | Estado implementación | Acción |
|---|---|---|---|
| A — Monolithic | Canónico (✓) | Canónico (✓) | **NO TOCAR** |
| B — Microservices | Canónico (✓) | Canónico (✓) | **NO TOCAR** |
| C — Dynamic Module Loading | Component Manager + plugins .so | **FastAPI + subprocess.Popen** (~30% match) | **RE-IMPLEMENTAR** (Fase 2) |
| D — Overlay Workspaces | Base + overlay separados, OTA delivery | **Una imagen monolítica con dos colcon ws dentro** (~30% match) | **RE-IMPLEMENTAR** (Fase 1) |

---

## 2. Decisiones cerradas con justificación

### 2.1 Backend de entrega del overlay

**Decisión**: imagen Docker como **OCI carrier** (no GitLab Generic Package Registry).

**Justificación**:
- Reusa `docker login` ya existente; no requiere token API GitLab adicional.
- `docker buildx build --push` es el flujo que Laura ya domina.
- Es el patrón GitOps moderno (ArgoCD, Flux, Tekton, Cosign lo usan así).
- Más alineado con producción 2026 que la API legacy de Generic Packages.

**Rechazado**:
- API GitLab Generic Packages (introduce auth y tooling separados).
- Helm chart con archivos embebidos (límite ConfigMap ~1 MB; modelos pesan GB).
- HTTP server externo (no autenticado, no versionado).

### 2.2 Patrón cloud-edge para acceso al overlay

**Decisión**: **Patrón B (sync at startup)** — Job pre-install descarga overlay a
PVC en kb2 (cloud), initContainer del Pod en edgenode01 sync de kb2 a `emptyDir`
local antes de arrancar el container principal.

**Justificación (alineada con el paper)**:
- Robots de producción operan tolerando partición de red. NFS continuo (Patrón A)
  asume conexión 100%, lo cual NO encaja con el modelo cloud-edge del paper.
- El init container con sync ES literalmente el "OTA install step" canónico.
- Frameworks reales (Mender, Balena, OSTree, snap, apt) siguen este patrón:
  pull → install → run local.
- Una vez los pods están arriba, las lecturas son locales rápidas — no afecta
  la latencia de inferencia que se va a medir en el benchmark.

**Rechazado**:
- Patrón A (NFS-backed PVC): asume conexión continua, no realista para edge.
- Patrón C (sidecar overlay manager con OTA continuo): fuera de alcance.

### 2.3 Cómo expone kb2 el contenido del PVC al edge

**Decisión**: **HTTP sidecar nginx** en kb2 que sirve el contenido del PVC en
`/srv/overlay/...`. El initContainer del Pod en edge usa `wget` o `curl` para
descargar a `emptyDir`.

**Justificación**:
- Sin gestión de claves SSH ni rsyncd.
- Encriptación implícita en la red privada del cluster K3s.
- Para un setup de fábrica con WAN, se cambiaría a HTTPS + auth, pero eso es
  configuración, no arquitectura.

**Rechazado**:
- rsync over SSH (más realista pero requiere gestión de keys).
- rsyncd (protocolo no estándar moderno).

**Caveat reconocido**: si nginx encuentra problemas con el modo RWO del PVC
local-path, pivotamos a SSH. Se valida al implementar, no antes.

### 2.4 Reparto de contenido entre `ros2-base` y `ros2-overlay-pack`

**Decisión revisada (2026-04-27, tras feedback de Laura)**: máxima reducción de la
imagen base, alineada con el paper.

| Componente | Ubicación | Justificación |
|---|---|---|
| ROS 2 Humble core (rclpy, ament, launch, lifecycle) | `base` | Plataforma común inmutable |
| `camera_driver_pkg` | `base` | Driver de hardware |
| CycloneDDS + rmw_cyclonedds_cpp | `base` | Transport core |
| CUDA L4T libs + cuDNN + `cusparselt_stub.so` | `base` | Tied to JetPack 6.1 |
| `numpy` (1.26 — pin documentado) | `base` | Lo necesita ROS 2 nativamente |
| **PyTorch wheel Jetson + torchvision + torchaudio** | **overlay** | ML runtime |
| **transformers + accelerate + bitsandbytes + mistral-common** | **overlay** | ML runtime |
| **sounddevice + librosa + soundfile** | **overlay** | Audio stack — específico Voxtral |
| `yolo_detector_pkg`, `llava_pkg`, `voxtral_pkg` (compilados) | **overlay** | Application AI nodes |
| Pesos HF de LLaVA + Voxtral | **overlay** | Modelos |

**Justificación de poner ML runtime en overlay**:
- Cita literal del paper: "*the base layer can be a proven read-only platform*".
  PyTorch evoluciona rápido y no encaja como "trusted, immutable platform".
- Cita literal del paper: "*different robots may need different sets of AI models*".
  Si PyTorch está en base, eliminamos esa flexibilidad — un overlay con TensorRT-only
  ya no es posible.
- El paper RECONOCE el coste explícitamente: "*include dependencies in the overlay
  as needed, but this increases the size of the overlay*". Aceptamos ese coste.

**Tamaños esperados**:
- `ros2-base`: ~2.5-3.5 GB (estable durante meses)
- `ros2-overlay-pack`: ~17-19 GB (PyTorch ~5 GB + transformers ~1 GB +
  paquetes nodos ~50 MB + modelos HF ~13 GB)

**Caveat reconocido**: cada update de modelo o de código de nodo mueve PyTorch
en el rebuild. Mitigación parcial vía Docker layer caching (orden de capas en
Dockerfile separa pip install de copy de fuentes). El **ancho de banda real
subido** a la registry es solo el delta (la registry deduplica capas comunes).

### 2.5 Versionado del overlay

**Decisión**: tag de la imagen `ros2-overlay-pack` solo `:latest`.

**Justificación**:
- Restricción de espacio en la registry de la usuaria (mencionada explícitamente).

**Caveat reconocido**: rollback no es trivial. Si `:latest` apunta a un overlay
roto, la única salida es rebuildear el overlay viejo desde git y republicar.
**Esto se documenta en el paper como una limitación operacional del setup
actual, pero NO es una limitación arquitectónica del patrón overlay**. En un
setup con espacio suficiente se usaría SemVer + latest.

### 2.6 Layout del PVC en kb2

**Decisión**: subdirectorios versionados.

```
/pvc/overlay/
  ├── 5.9.0/
  │   ├── install/                     ← workspace overlay compilado
  │   └── huggingface_cache/           ← modelos HF
  ├── 5.10.0/
  │   ├── install/
  │   └── huggingface_cache/
  └── ...
```

El StatefulSet apunta a la versión activa vía Helm value (que viene del
`Chart.version`). `helm rollback` cambia ese valor y el pod remonta el
subdirectorio anterior.

**Caveat reconocido**: combinado con la decisión 2.5 (solo `:latest`), el
contenido versionado vive solo en kb2, no en la registry. Si se borra `kb2`
o se pierde el PVC, no se puede recuperar versiones viejas. Se acepta para
este setup. **Cleanup automático de versiones viejas**: tarea futura cuando
el disco apure.

### 2.7 CI/CD

**Decisión**: GitHub Actions **solo publica Helm charts a gh-pages**. NO
construye imágenes Docker.

**Justificación**:
- Decisión explícita de Laura: el ciclo de iteración manual de imágenes ya
  está controlado con `docker buildx build --push` desde su Mac.
- Evitar drift entre imágenes "del CI" e imágenes "manuales" pusheadas.

**Implicación**: `.github/workflows/build-and-publish.yaml` se simplifica
para eliminar todos los pasos de docker build/push. Solo queda el job de
empaquetado y publicación de Helm a gh-pages.

### 2.8 Tipo de component container para Patrón C

**Decisión**: `component_container_isolated` (Python).

**Justificación**:
- Cada componente recibe su propio `MultiThreadedExecutor` — robusto frente a
  callbacks bloqueantes.
- `component_container` (single-threaded) bloquearía si LLaVA está en inferencia
  de 12 s y otro componente quiere procesar.
- `component_container_mt` es C++ only, no compatible con paquetes Python.

**Caveat reconocido**: rclpy_components tiene limitaciones documentadas
respecto al C++ canónico:
- No comparte memoria zero-copy entre nodos cargados (Python GIL).
- Algunos paquetes pueden no ser componentizables si usan threads no-rclpy
  (ej. `sounddevice` en Voxtral).

**Mitigación específica para Voxtral**: el fix cosmético del mic loop
(probar `sd.query_devices()` antes de arrancar) ya está en el código.
Voxtral en component container detecta `/dev/snd` ausente y desactiva el
mic loop solo, sin error.

### 2.9 Imagen para el component host

**Decisión**: nueva imagen **`ros2-component-host:latest`**.

**Justificación**:
- Reusar `ros2-monolithic` arrastraría peso innecesario y mezcla responsabilidades.
- Una imagen específica permite optimizar la lista de plugins disponibles.

**Contenido esperado de `ros2-component-host`**:
- Base ROS 2 Humble
- Los cuatro paquetes refactorizados (`camera_driver_pkg`, `yolo_detector_pkg`,
  `llava_pkg`, `voxtral_pkg`) con entry_points `rclpy_components`.
- Stack ML completo (PyTorch, transformers, etc.) — necesita estar en el host
  porque los componentes se cargan en el mismo proceso del host.
- Modelos HF empotrados (mismo patrón que ya usa monolithic).
- FastAPI + rclpy client del orchestrator.

### 2.10 Estrategia de carga del Patrón C

**Decisión**: a demanda vía HTTP del orchestrator. El pod arranca **sin
componentes cargados**. Cargar/descargar via `POST /load`, `POST /unload`.

**Justificación**:
- Es el punto del patrón Dynamic Module Loading: hot-swap.
- Cargar todo al arranque eliminaría la diferencia con monolithic.

**Pregunta abierta** (a cerrar al implementar): ¿el dashboard dispara una carga
inicial automática al primer connect del browser, o se expone un botón
"Initialize" en la UI? **Decisión**: lo decidimos al implementar la UI; no
afecta a la arquitectura.

---

## 3. FASE 1 — Patrón D (Overlay) canónico

### 3.1 Arquitectura objetivo

```
┌──────────────────────────────────────────────────────────────────────┐
│ GitLab Container Registry (gitlab-cigip.alc.upv.es:5050)             │
│   ros2-base:latest         (~3 GB, ROS 2 + camera + CUDA)            │
│   ros2-overlay-pack:latest (~17 GB, ML runtime + nodos AI + modelos) │
└──────────────────────────────────────────────────────────────────────┘
                          │
                          │ helm install dispara hook pre-install
                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Helm pre-install Job (corre en kb2)                                  │
│   image: ros2-overlay-pack:latest                                    │
│   command: cp -av /opt/overlay/. /pvc/overlay/{{.Chart.Version}}/    │
│   volumeMounts: PVC overlay-source en /pvc                           │
│   hook-delete-policy: hook-succeeded                                 │
└──────────────────────────────────────────────────────────────────────┘
                          │
                          │ deja contenido aquí
                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ PVC overlay-source                                                   │
│   StorageClass: local-path (kb2)                                     │
│   AccessMode: ReadWriteOnce                                          │
│   Size: 30 GB                                                        │
│   Layout:                                                            │
│     /pvc/overlay/5.9.0/install/                                      │
│     /pvc/overlay/5.9.0/huggingface_cache/                            │
│     /pvc/overlay/5.10.0/...                                          │
└──────────────────────────────────────────────────────────────────────┘
                          │
                          │ servido por
                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ overlay-server: Pod nginx en kb2                                     │
│   imagen: nginx:alpine                                               │
│   monta el PVC overlay-source en /usr/share/nginx/html (read-only)   │
│   expone Service ClusterIP overlay-server.ros2exp.svc.cluster.local  │
└──────────────────────────────────────────────────────────────────────┘
                          │
                          │ HTTP GET desde init container
                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Pod overlay-runtime (corre en edgenode01)                            │
│   nodeSelector: edgenode01                                           │
│   initContainer "overlay-sync":                                      │
│     - imagen: alpine + curl/wget                                     │
│     - URL: http://overlay-server.../overlay/{{.Chart.Version}}/      │
│     - target: emptyDir /opt/overlay                                  │
│   container "main":                                                  │
│     - imagen: ros2-base:latest                                       │
│     - volumeMounts: emptyDir en /opt/overlay (read-only)             │
│     - env: HF_HUB_OFFLINE=1, HF_HOME=/opt/overlay/huggingface_cache  │
│     - entrypoint:                                                    │
│         source /opt/ros/humble/setup.bash                            │
│         source /opt/base_ws/install/setup.bash                       │
│         source /opt/overlay/install/setup.bash                       │
│         ros2 run yolo_detector_pkg yolo_detector &                   │
│         ros2 run llava_pkg llava_node &                              │
│         ros2 run voxtral_pkg voxtral_node &                          │
│         ros2 run camera_driver_pkg camera_driver &                   │
│         wait -n                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Componentes a crear

#### Imágenes Docker nuevas

```
Models/ros2_base/
  docker/Dockerfile              ← multi-stage: ROS 2 + L4T CUDA + numpy
  src/                            ← link a Models/ros2_cam_ws/src/camera_driver_pkg

Models/ros2_overlay_pack/
  docker/Dockerfile              ← FROM ros2-base + ML stack + AI nodes + modelos
  scripts/build_tarball.sh       ← (NO necesario si vamos por OCI carrier)
```

#### Helm chart nuevo (paralelo al actual)

```
Patterns/overlay-canonical/
  helm/ros2-overlay-canonical/
    Chart.yaml                                     ← name: ros2-overlay-canonical, version: 1.0.0
    values.yaml                                    ← parametrización
    templates/
      _helpers.tpl
      pvc-source.yaml                             ← PVC overlay-source en kb2
      pre-install-job.yaml                         ← Job hook con imagen overlay-pack
      overlay-server-deployment.yaml               ← nginx en kb2
      overlay-server-service.yaml                  ← ClusterIP
      statefulset-runtime.yaml                     ← Pod en edgenode01 con initContainer
      headless-service.yaml                        ← DDS peers (con publishNotReadyAddresses)
      cyclonedds-configmap.yaml
      dashboard-statefulset.yaml                   ← reusa lo de overlay-workspaces
      dashboard-configmap.yaml
      dashboard-service.yaml
      benchmark-job.yaml                           ← copy del actual
```

`Patterns/overlay-workspaces/` (versión actual con todo en una imagen) **no se borra
hasta que `overlay-canonical` esté validado**. Cuando lo esté, se renombra:

```
Patterns/overlay-workspaces/        → Patterns/overlay-workspaces-deprecated/
Patterns/overlay-canonical/         → Patterns/overlay-workspaces/
```

### 3.3 Plan paso a paso (Fase 1)

| # | Tarea | Resultado verificable |
|---|---|---|
| 1 | Crear `Models/ros2_base/docker/Dockerfile` | `docker build` produce imagen ~3 GB con ROS 2 + camera + CUDA |
| 2 | Crear `Models/ros2_overlay_pack/docker/Dockerfile` | Imagen ~17 GB con ML stack + AI nodes + modelos. Build usa `--secret id=hf_token` |
| 3 | Test: `docker run ros2-overlay-pack ls /opt/overlay/install` muestra los paquetes | OK |
| 4 | Crear `Patterns/overlay-canonical/helm/ros2-overlay-canonical/Chart.yaml` y `values.yaml` | helm template no falla |
| 5 | Crear `pvc-source.yaml` y verificar que K3s crea el PVC con `kubectl apply -f` | PVC en estado `Bound` |
| 6 | Crear `pre-install-job.yaml` con annotations Helm hook | Job se crea en helm install y termina con éxito |
| 7 | Crear `overlay-server-deployment.yaml` (nginx) y `overlay-server-service.yaml` | `curl http://overlay-server:80/overlay/1.0.0/install/setup.bash` desde otro pod devuelve 200 |
| 8 | Crear `statefulset-runtime.yaml` con initContainer de sync | Pod arranca, init container completa, main container ve `/opt/overlay/install` |
| 9 | Verificar que los nodos arrancan y publican topics | `ros2 topic list` muestra `/camera/image_raw`, `/detections`, `/llava/response`, `/voice/transcript` |
| 10 | Validar end-to-end con dashboard | Misma funcionalidad que microservices, pero arquitectura overlay |
| 11 | Medir métricas para el paper | Tabla comparativa vs monolithic |
| 12 | Borrar `Patterns/overlay-workspaces/` viejo, renombrar canónico | Limpieza |

### 3.4 Riesgos identificados (Fase 1)

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| `local-path` PVC en kb2 con RWO no permite el patrón Job-escribe-sidecar-lee | Media | Pivotar a `hostPath` directo o instalar `csi-driver-nfs` si surge |
| Versión de PyTorch en overlay no encaja con CUDA en base | Baja | Build-arg `BASE_CUDA_VERSION` validado al build |
| HTTP sidecar nginx no sirve archivos grandes (~13 GB modelos) eficientemente | Baja | `client_max_body_size` y buffer adecuados; o pivotar a `nginx-cdn-style` con `sendfile on` |
| Init container rsync timeout en pull de 17 GB | Media | Configurar timeout init container amplio; añadir progress logging |
| Helm pre-install hook no garantiza estado del PVC al inicio del StatefulSet | Baja | Validar con `helm install` real; si hace falta, añadir `helm.sh/hook-weight` |

---

## 4. FASE 2 — Patrón C (Dynamic Module Loading) canónico

### 4.1 Arquitectura objetivo

```
┌──────────────────────────────────────────────────────────────────────┐
│ Pod único: dyn-pattern-dynamic-loader-host-0 (en edgenode01)         │
│                                                                      │
│  ┌─────────────────────────────┐  ┌─────────────────────────────┐  │
│  │ Container 1: component-host │  │ Container 2: orchestrator   │  │
│  │   imagen: ros2-component-   │  │   imagen: ros2-component-   │  │
│  │     host:latest             │  │     host:latest             │  │
│  │   command:                  │  │   command:                  │  │
│  │     ros2 run rclpy_         │  │     uvicorn fastapi_app:app │  │
│  │     components              │  │                             │  │
│  │     component_container_    │  │   Endpoints:                │  │
│  │     isolated                │  │     POST /load   { module } │  │
│  │                             │  │     POST /unload { module } │  │
│  │   Servicios expuestos:      │  │     GET  /list              │  │
│  │     /ComponentManager/      │  │                             │  │
│  │       load_node             │  │   Backend: rclpy.Node como  │  │
│  │       unload_node           │  │     cliente de              │  │
│  │       list_nodes            │  │     /ComponentManager/      │  │
│  │                             │  │       load_node             │  │
│  │   Plugins disponibles:      │  │                             │  │
│  │     camera_driver_pkg       │  │ (ya NO usa subprocess.Popen)│  │
│  │     yolo_detector_pkg       │  │                             │  │
│  │     llava_pkg               │  │                             │  │
│  │     voxtral_pkg             │  │                             │  │
│  └─────────────────────────────┘  └─────────────────────────────┘  │
│                                                                      │
│  Comparten: misma red (localhost), mismo PID namespace               │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.2 Componentes a crear/modificar

#### Refactor de paquetes existentes (sin romper monolithic/microservices/overlay)

Cada uno de los siguientes paquetes se modifica añadiendo un entry_point
`rclpy_components` SIN tocar el `main()` existente, así que sigue funcionando
en los otros tres patrones:

```
Models/ros2_cam_ws/src/camera_driver_pkg/
  setup.py                                      ← añadir entry_point rclpy_components

Models/ros2_yolo_ws/src/yolo_detector_pkg/
  setup.py                                      ← idem

Models/ros2_llava_ws/src/llava_pkg/
  setup.py                                      ← idem

Models/ros2_voxtral_ws/src/voxtral_pkg/
  setup.py                                      ← idem
```

Patrón del cambio:

```python
entry_points={
    'console_scripts': [
        'camera_driver = camera_driver_pkg.camera_driver:main',  # patrones A/B/D
    ],
    'rclpy_components': [
        'CameraDriver = camera_driver_pkg.camera_driver:CameraDriver',  # patrón C
    ],
}
```

Las clases (`CameraDriver`, `YoloDetector`, `LlavaNode`, `VoxtralNode`) deben:
- NO llamar `rclpy.init()` ni `rclpy.spin()` desde su `__init__`.
- Aceptar `**kwargs` en el constructor para que el component container les pase
  el contexto.

#### Imagen Docker nueva

```
Models/ros2_component_host/
  docker/Dockerfile              ← FROM ros2-base + ML stack + 4 paquetes refactorizados + FastAPI
```

#### Helm chart refactor

```
Patterns/dynamic-canonical/
  helm/dynamic-loader-canonical/
    Chart.yaml
    values.yaml
    templates/
      statefulset.yaml             ← pod con 2 containers (component-host + orchestrator)
      cyclonedds-configmap.yaml
      dashboard-*.yaml
      benchmark-job.yaml
```

### 4.3 Plan paso a paso (Fase 2)

| # | Tarea | Resultado verificable |
|---|---|---|
| 1 | Refactor `camera_driver_pkg`: clase componentizable + dual entry_point | `pip install -e .` ofrece ambos entry_points |
| 2 | Test unitario: `ros2 component load /ComponentManager camera_driver_pkg CameraDriver` carga sin error | OK |
| 3 | Lo mismo para `yolo_detector_pkg` | OK |
| 4 | Lo mismo para `llava_pkg` (validar timeout de carga del modelo en service call) | LoadNode devuelve OK en <60 s |
| 5 | Lo mismo para `voxtral_pkg` (mic loop ya tolera /dev/snd ausente) | OK |
| 6 | Crear `Models/ros2_component_host/docker/Dockerfile` | Imagen ~17-19 GB |
| 7 | Crear FastAPI orchestrator con rclpy client (en `Models/ros2_component_host/src/orchestrator/`) | `POST /load { "module": "yolo" }` invoca el service de ROS 2 |
| 8 | Crear chart `Patterns/dynamic-canonical/` con pod 2-container | `helm template` no falla |
| 9 | Deploy y test: el pod arranca sin componentes, dashboard dispara `/load` para cada uno | Topics aparecen progresivamente |
| 10 | Validar hot-swap: `/unload yolo` + `/load yolo` sin reiniciar pod | El topic `/detections` desaparece y reaparece |
| 11 | Medir métricas | RAM con N módulos + tiempo de LoadNode + latencia inter-componente |
| 12 | Renombrar canónico → reemplazar `dynamic-loader/` viejo | Limpieza |

### 4.4 Riesgos identificados (Fase 2)

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| `LlavaNode` `__init__` carga modelo (~12 s); el service `LoadNode` por defecto tiene timeout 60 s | Baja | Carga lazy: `__init__` rápido, modelo se carga al primer mensaje |
| `voxtral_node` cuando arranca el mic thread bloquea o crashea el component container | Media | Ya mitigado: query_devices antes; loop sale solo si no hay /dev/snd |
| `rclpy_components` no soporta algún tipo de servicio/topic que usan los nodos | Baja | Validar al refactorizar nodo por nodo |
| Componentes cargados en mismo proceso pisan globals (ej. `torch.cuda.set_device`) | Media | Acotar globals; usar `torch.cuda.device(0)` context manager |
| Memory leak al hacer múltiples load/unload de LLaVA | Media | Documentar como limitación; medir en benchmark |

---

## 5. FASE 3 — Mediciones y benchmark (placeholder)

A definir en detalle cuando Fase 1 y 2 estén implementadas. Incluirá:

### 5.1 Métricas para el paper

| Métrica | Patrón A (Mono) | Patrón B (Micro) | Patrón C (Dyn) | Patrón D (Overlay) |
|---|---|---|---|---|
| Tamaño imagen entregada | ~22 GB | ~15-20 GB c/u (5 imgs) | ~17 GB | ~3 GB base + ~17 GB overlay |
| Delta de update (cambio modelo) | 22 GB | imagen afectada | 17 GB | solo overlay (~17 GB) |
| Tiempo arrancar pod | ~70 s | ~80 s | ~10 s base + N×~15 s | ~70-90 s (con sync) |
| RAM total runtime | medir | medir | medir | medir |
| Latencia YOLO→LLaVA (DDS) | <1 ms | 5-15 ms | <1 ms (mismo proceso) | <1 ms |
| Hot-swap | No | No (rolling restart) | Sí (load/unload service) | No (helm upgrade) |
| Tolerancia desconexión cloud | N/A | N/A | N/A | Sí (modelo en local) |

### 5.2 Procedimiento de medición

A diseñar.

---

## 6. Lo que NO se toca

- ✅ **Patrón A (Monolithic)** — `Patterns/monolithic/`, `Models/ros2_monolithic_ws/`.
- ✅ **Patrón B (Microservices)** — `Patterns/microservices/`, imágenes individuales.
- ✅ **Modelos LLaVA y Voxtral** — se siguen empotrando vía `snapshot_download` con
  HF_TOKEN como BuildKit secret.
- ✅ **Dashboard** — sigue siendo un pod separado con nginx + rosbridge. Mismo HTML.
- ✅ **`HF_HUB_OFFLINE=1` + `HF_HOME=/opt/huggingface_cache`** — patrón de carga de
  modelos local, ya validado.
- ✅ **`numpy>=1.23,<2`** — pin documentado, no se toca.
- ✅ **InitContainer `wait-for-peers`** + `publishNotReadyAddresses: true` en
  headless services — ya implementado, se reusa en los charts canónicos.
- ✅ **`local_files_only=True` + `snapshot_download` para resolver path local** en
  `voxtral_node.py` — workaround validado, se mantiene.

---

## 7. Esfuerzo estimado y orden de ejecución

| Fase | Tarea | Esfuerzo |
|---|---|---|
| 1 | D-1 Split imágenes | 0.5 día |
| 1 | D-2 OCI carrier publish (build script) | 0.5 día |
| 1 | D-3 PVC + storage class | 0.25 día |
| 1 | D-4 Helm pre-install Job | 0.5 día |
| 1 | D-5 nginx sidecar + Service | 0.5 día |
| 1 | D-6 StatefulSet + initContainer rsync | 0.5 día |
| 1 | D-7 Validación end-to-end | 0.5 día |
| 1 | D-8 Benchmark y métricas | 0.5 día |
| **Total Fase 1** | | **~3.5 días** |
| 2 | C-1 Refactor `camera_driver_pkg` | 0.5 día |
| 2 | C-2 Refactor `yolo_detector_pkg` | 0.5 día |
| 2 | C-3 Refactor `llava_pkg` (lazy load del modelo) | 1 día |
| 2 | C-4 Refactor `voxtral_pkg` | 0.5 día |
| 2 | C-5 FastAPI orchestrator → rclpy client | 1 día |
| 2 | C-6 Imagen `ros2-component-host` | 0.5 día |
| 2 | C-7 Helm chart pod 2-container | 0.5 día |
| 2 | C-8 Validación end-to-end + hot-swap | 1 día |
| 2 | C-9 Benchmark | 0.5 día |
| **Total Fase 2** | | **~6 días** |
| **Total proyecto** | | **~9.5 días full-time** |

**Orden estricto**: Fase 1 → Fase 2 → Fase 3. NO empezar Fase 2 hasta que
Fase 1 esté validada en cluster real.

---

## 8. Comandos clave (referencia rápida)

### Build y push de las imágenes nuevas

```bash
export HF_TOKEN="hf_xxxxxxxxxxxxxxxx"
export REG="gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes"

# ros2-base
docker buildx build \
  --build-arg TORCH_VARIANT=auto \
  --platform linux/arm64 \
  -t "${REG}/ros2-base:latest" \
  -f Models/ros2_base/docker/Dockerfile \
  --provenance=false --push .

# ros2-overlay-pack (necesita HF_TOKEN para Voxtral gated)
DOCKER_BUILDKIT=1 docker buildx build \
  --secret id=hf_token,env=HF_TOKEN \
  --build-arg TORCH_VARIANT=auto \
  --platform linux/arm64 \
  -t "${REG}/ros2-overlay-pack:latest" \
  -f Models/ros2_overlay_pack/docker/Dockerfile \
  --provenance=false --push .

# ros2-component-host (Fase 2)
DOCKER_BUILDKIT=1 docker buildx build \
  --secret id=hf_token,env=HF_TOKEN \
  --build-arg TORCH_VARIANT=auto \
  --platform linux/arm64 \
  -t "${REG}/ros2-component-host:latest" \
  -f Models/ros2_component_host/docker/Dockerfile \
  --provenance=false --push .
```

### Deploy y test

```bash
# Fase 1
helm upgrade --install overlay-pattern \
  Patterns/overlay-canonical/helm/ros2-overlay-canonical/ \
  -n ros2exp --create-namespace

# Fase 2
helm upgrade --install dyn-pattern \
  Patterns/dynamic-canonical/helm/dynamic-loader-canonical/ \
  -n ros2exp --create-namespace
```

### Limpieza de containerd en edgenode01

```bash
ssh edgenode01
sudo k3s ctr images list | grep ros2-base | awk '{print $1}' | \
  xargs -r -n1 sudo k3s ctr images rm
sudo k3s ctr images list | grep ros2-overlay-pack | awk '{print $1}' | \
  xargs -r -n1 sudo k3s ctr images rm
sudo k3s crictl rmi --prune
```

---

## 9. Criterios de "definición de hecho"

### Para Fase 1

- [ ] `ros2-base:latest` y `ros2-overlay-pack:latest` están en la registry GitLab.
- [ ] `helm install overlay-canonical` deploys sin errores.
- [ ] El Job pre-install termina con éxito y el PVC en kb2 contiene
      `/pvc/overlay/{version}/install` y `/pvc/overlay/{version}/huggingface_cache`.
- [ ] El nginx sidecar responde HTTP 200 con el contenido.
- [ ] El initContainer del pod en edgenode01 baja el contenido a `/opt/overlay`.
- [ ] Camera + YOLO + LLaVA + Voxtral arrancan dentro del pod.
- [ ] Dashboard muestra `Pattern: overlay-canonical`.
- [ ] Pulsar Record en el dashboard transcribe + dispara LLaVA + responde.
- [ ] Documento PLAN actualizado con métricas reales medidas.

### Para Fase 2

- [ ] Los 4 paquetes refactorizados tienen entry_points `rclpy_components`.
- [ ] `ros2 component load` carga cada uno individualmente sin error.
- [ ] `ros2-component-host:latest` está en la registry.
- [ ] El pod 2-container arranca sin componentes cargados.
- [ ] Dashboard puede invocar `POST /load` para cada componente.
- [ ] Hot-swap (`/unload` + `/load` del mismo módulo) funciona sin reiniciar pod.
- [ ] Voice + Visual flow funcionan con todos los componentes cargados.
- [ ] Documento PLAN actualizado con métricas reales medidas.

---

## 10. Notas honestas y desviaciones reconocidas

Esta sección existe explícitamente porque Laura pidió "no inventar, no ser
complaciente, tener en cuenta la teoría". Aquí se documentan las cosas que
no son ideales pero se aceptan por restricciones del proyecto.

1. **Tag `:latest` solo, sin SemVer en la registry**: por restricción de espacio.
   Implicación: rollback no es trivial, requiere rebuild manual.

2. **PyTorch en overlay genera updates de ~17 GB para cambios de modelo**:
   aceptado por alineación con la teoría que prima inmutabilidad de la base.

3. **`rclpy_components` NO da zero-copy intra-process** (Python GIL): aceptado
   como limitación documentada del approach Python vs C++ canónico. Se prioriza
   compatibilidad con el ecosistema Python (PyTorch, transformers).

4. **HTTP sidecar nginx no tiene auth**: aceptable para red privada del cluster
   K3s. En una fábrica con WAN se cambiaría por HTTPS + auth.

5. **CI no construye imágenes**: aceptado por decisión explícita de Laura.
   Implicación: el repo y la registry pueden divergir si Laura no recuerda
   pushear manualmente. Mitigación: `make publish-images` script que
   automatiza el flujo.

6. **`overlay-canonical` y `overlay-workspaces` (viejo) coexisten temporalmente**:
   evita romper despliegues actuales. Decisión: no borrar el viejo hasta validar
   el canónico en producción.

---

**FIN DEL PLAN**
