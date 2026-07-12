# results/topology/ — Evidencia de topología de procesos (R1.3)

**Estado (2026-07-07): PENDIENTE DE CAPTURA.** El script está listo pero requiere
ejecutarse desde una máquina con `kubectl` contra el cluster (esta carpeta se
rellenará con la salida real; no se ha fabricado ningún dato).

## Propósito

El revisor 1 (comentario R1.3) señala una contradicción del manuscrito: la Sec. IV-C-1
describe el patrón monolítico como "un único proceso Python", mientras que la Sec. V-C
(correctamente, según el código) lo describe como procesos OS separados. Esta carpeta
almacena la **evidencia capturada del cluster real** de la topología
nodo → pod → contenedor → procesos de cada patrón, que sustentará:

- la corrección de las Secciones III-A y IV-C del manuscrito,
- la nueva figura "process-and-container diagram" por patrón,
- la respuesta al comentario R1.3 (y a la discrepancia I-2 del plan: el paper sitúa
  el orquestador FastAPI en el cloud, pero el chart lo despliega como contenedor
  hermano del component host en el pod del edge).

## Cómo ejecutar la captura (manual, ~10 min, solo lectura)

```bash
# 1. Entrar en el nodo de control (FQDN obligatorio; kb2 no resuelve nombres cortos)
ssh administrador@kb1.cigip.upv.es
cd ~/Kubernetes-deployment-patterns && git pull

# 2. Desplegar el patrón (si no está ya desplegado). Ejemplo monolítico:
helm install monolithic-pattern Patterns/monolithic/helm -n ros2exp --create-namespace
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/instance=monolithic-pattern -n ros2exp --timeout=15m

# 3. Capturar (se puede limitar con PATTERNS="...")
bash scripts/benchmark/capture_process_topology.sh

# 4. Repetir para cada patrón (release names: monolithic-pattern,
#    microservices-pattern, overlay-pattern, dynamic-pattern) y volver a ejecutar
#    el script; los patrones no desplegados se saltan automáticamente.

# 5. Commitear la salida
git add results/topology && git commit -m "R1.3: process/container topology evidence"
```

Nota: si los 4 patrones no pueden convivir (recursos GPU del Jetson), capturar
de uno en uno: install → wait Ready → capture → uninstall → siguiente. El script
no instala ni desinstala nada por sí mismo (es estrictamente de solo lectura).

## Artefactos esperados por patrón

```
results/topology/<pattern>/<TIMESTAMP>/
  00_cluster_nodes.txt      # nodos del cluster (arquitectura, roles)
  01_pods_wide.txt          # pods de la release y nodo donde corren
  02_pods.json              # spec completa: contenedores e initContainers por pod
  03_workloads.txt          # statefulsets / deployments / jobs
  <pod>__<container>__ps.txt        # ps -ef
  <pod>__<container>__pstree.txt    # árbol de procesos (ps axjf)
  <pod>__<container>__procwalk.txt  # /proc: pid|ppid|threads|rss|cmdline (fuente canónica)
  <pod>__<container>__ros2nodes.txt # ros2 node list (grafo DDS visto desde el contenedor)
  <pod>__<container>__components.txt # solo dynamic-loader: ros2 component list
results/topology/SUMMARY_<TIMESTAMP>.md   # veredicto automático por patrón
```

## Resultado esperado (hipótesis a confirmar con la captura, según el código)

| Patrón | Pods (runtime) | Contenedores | Procesos de nodos IA |
|---|---|---|---|
| monolithic | 1 (edge) + dashboard (cloud) | 1 runtime | **4 procesos OS separados** (`ros2 run` por nodo; ver args del StatefulSet) |
| microservices | 5 (4 edge + dashboard cloud) | 1 por pod | 4 procesos en 4 pods distintos |
| overlay | 1 runtime (edge) + overlay-server y dashboard (cloud) | init (sync) + runtime | 4 procesos OS separados |
| dynamic-loader | 1 (edge) + dashboard (cloud) | component-host + orchestrator (¡mismo pod, ambos en edge!) | **1 proceso** `component_container_isolated` con los 4 nodos como componentes |

Si la captura contradice esta tabla, prevalece la captura y se corrige el plan
y el manuscrito en consecuencia.
