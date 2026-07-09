#!/usr/bin/env bash
# =============================================================================
# capture_process_topology.sh — Evidencia de topología procesos/contenedores
# =============================================================================
# Responde al comentario R1.3 de la revisión de IEEE Access: captura, para cada
# patrón desplegado, la topología real nodo -> pod -> contenedor -> procesos OS,
# con detalle suficiente para determinar si los nodos ROS 2 comparten proceso
# (dynamic-loader: 4 componentes en un component_container_isolated) o corren
# como procesos separados (monolithic, microservices, overlay).
#
# SOLO LECTURA: no instala, no borra, no reinicia nada. Usa kubectl get/exec.
#
# Salida: results/topology/<pattern>/<TIMESTAMP>/
#   00_cluster_nodes.txt              kubectl get nodes -o wide
#   01_pods_wide.txt                  pods de la release + nodo asignado
#   02_pods.json                      spec+status completos (containers, initContainers)
#   03_workloads.txt                  statefulsets/deployments/jobs de la release
#   <pod>__<container>__ps.txt        ps -ef dentro del contenedor (si hay ps)
#   <pod>__<container>__pstree.txt    árbol de procesos (ps axjf, forest)
#   <pod>__<container>__procwalk.txt  volcado /proc: pid|ppid|threads|rss|cmdline
#                                     (funciona aunque el contenedor no tenga ps)
#   <pod>__<container>__ros2nodes.txt ros2 node list visto desde ese contenedor
#                                     (grafo DDS completo; best-effort)
#   <pod>__<container>__components.txt  ros2 component list (solo dynamic-loader;
#                                     demuestra qué componentes viven en qué proceso)
# y en results/topology/:
#   SUMMARY_<TIMESTAMP>.md            veredicto automático por patrón (R1.3)
#
# Uso (desde una máquina con kubectl configurado contra el cluster, p.ej. kb2):
#   bash scripts/benchmark/capture_process_topology.sh
#   PATTERNS="monolithic dynamic-loader" bash scripts/benchmark/capture_process_topology.sh
#
# Variables de entorno (opcionales):
#   NAMESPACE   Default ros2exp
#   PATTERNS    Default "monolithic microservices overlay dynamic-loader"
#   ROS_SETUP   Default /opt/ros/humble/setup.bash (para ros2 node list)
#
# Requisitos:
#   - kubectl con acceso al cluster (KUBECONFIG o ~/.kube/config)
#   - los patrones a capturar deben estar desplegados (helm install previo).
#     Los patrones no desplegados se saltan con aviso; no es un error.
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:-ros2exp}"
PATTERNS="${PATTERNS:-monolithic microservices overlay dynamic-loader}"
ROS_SETUP="${ROS_SETUP:-/opt/ros/humble/setup.bash}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_BASE="${PROJECT_ROOT}/results/topology"
TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY="${OUT_BASE}/SUMMARY_${TS}.md"

# Tokens de proceso que identifican a los nodos IA y al host de composición.
# Se buscan en las cmdlines capturadas para emitir el veredicto por patrón.
NODE_TOKENS="camera_driver yolo_detector llava voxtral component_container orchestrator"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl no está disponible en esta máquina." >&2
  echo "Ejecuta este script desde kb2 (o cualquier host con KUBECONFIG del cluster):" >&2
  echo "  ssh administrador@kb1.cigip.upv.es" >&2
  echo "  cd ~/Kubernetes-deployment-patterns && git pull" >&2
  echo "  bash scripts/benchmark/capture_process_topology.sh" >&2
  exit 2
fi

# Mismo mapeo release<->patrón que run_full_campaign.sh (mantener en sincronía).
release_name_for() {
  case "$1" in
    monolithic)     echo "monolithic-pattern" ;;
    microservices)  echo "microservices-pattern" ;;
    overlay)        echo "overlay-pattern" ;;
    dynamic-loader) echo "dynamic-pattern" ;;
    *)              echo "$1-pattern" ;;
  esac
}

# Volcado de /proc dentro del contenedor. No depende de que exista ps/pstree:
# recorre /proc/<pid> y emite: pid|ppid|threads|rss|cmdline
# (cmdline vacía = kernel thread o proceso zombie; se etiqueta como tal).
PROC_WALK='for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
  [ -n "$cmd" ] || cmd="[sin cmdline: kernel/zombie]"
  ppid=$(awk "{print \$4}" "$d/stat" 2>/dev/null)
  threads=$(awk "/^Threads:/{print \$2}" "$d/status" 2>/dev/null)
  rss=$(awk "/^VmRSS:/{print \$2\" \"\$3}" "$d/status" 2>/dev/null)
  echo "$pid|ppid=$ppid|threads=$threads|rss=$rss|$cmd"
done'

capture_container() {
  # $1 pod, $2 container, $3 outdir
  local pod=$1 container=$2 outdir=$3
  local prefix="${outdir}/${pod}__${container}"

  # ps -ef clásico (si la imagen trae procps; busybox trae un ps reducido).
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${container}" -- \
    sh -c 'command -v ps >/dev/null 2>&1 && ps -ef || echo "ps no disponible en este contenedor"' \
    > "${prefix}__ps.txt" 2>&1 || echo "(exec fallo)" >> "${prefix}__ps.txt"

  # Árbol de procesos (forest). ps axjf muestra PPID->PID con sangría.
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${container}" -- \
    sh -c 'command -v ps >/dev/null 2>&1 && ps axjf 2>/dev/null || echo "ps axjf no disponible"' \
    > "${prefix}__pstree.txt" 2>&1 || echo "(exec fallo)" >> "${prefix}__pstree.txt"

  # Volcado /proc: SIEMPRE funciona, es la fuente canónica del veredicto.
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${container}" -- \
    sh -c "${PROC_WALK}" \
    > "${prefix}__procwalk.txt" 2>&1 || echo "(exec fallo)" >> "${prefix}__procwalk.txt"

  # Grafo ROS 2 visto desde este contenedor (best-effort: requiere ros2cli
  # en la imagen y discovery DDS; timeout para no colgar la captura).
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${container}" -- \
    bash -lc "source ${ROS_SETUP} >/dev/null 2>&1 && timeout 25 ros2 node list 2>&1 || echo 'ros2 node list no disponible en este contenedor'" \
    > "${prefix}__ros2nodes.txt" 2>&1 || echo "(exec fallo)" >> "${prefix}__ros2nodes.txt"
}

capture_components_dynamic() {
  # Solo dynamic-loader: lista de componentes cargados en el component container.
  # Demuestra que los 4 nodos IA viven DENTRO del mismo proceso host.
  local pod=$1 container=$2 outdir=$3
  local prefix="${outdir}/${pod}__${container}"
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${container}" -- \
    bash -lc "source ${ROS_SETUP} >/dev/null 2>&1 && timeout 25 ros2 component list 2>&1 || echo 'ros2 component list no disponible'" \
    > "${prefix}__components.txt" 2>&1 || echo "(exec fallo)" >> "${prefix}__components.txt"
}

# ── Cabecera del summary ─────────────────────────────────────────────────────
mkdir -p "${OUT_BASE}"
{
  echo "# Topología de procesos por patrón — captura ${TS}"
  echo
  echo "Evidencia para R1.3 (proceso/contenedor/pod/nodo por patrón)."
  echo "Namespace: \`${NAMESPACE}\`. Generado por \`capture_process_topology.sh\` (solo lectura)."
  echo
} > "${SUMMARY}"

log "Captura de topología -> ${OUT_BASE} (namespace=${NAMESPACE})"

for pattern in ${PATTERNS}; do
  RELEASE="$(release_name_for "${pattern}")"
  OUT_DIR="${OUT_BASE}/${pattern}/${TS}"

  log "── Patrón: ${pattern} (release ${RELEASE})"

  PODS=$(kubectl get pods -n "${NAMESPACE}" \
           -l "app.kubernetes.io/instance=${RELEASE}" \
           -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [ -z "${PODS}" ]; then
    log "   no hay pods desplegados para ${RELEASE}; se salta (helm install primero)."
    {
      echo "## ${pattern}"
      echo
      echo "**NO CAPTURADO**: la release \`${RELEASE}\` no estaba desplegada en el momento de la captura."
      echo
    } >> "${SUMMARY}"
    continue
  fi

  mkdir -p "${OUT_DIR}"

  kubectl get nodes -o wide > "${OUT_DIR}/00_cluster_nodes.txt" 2>&1
  kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o wide \
    > "${OUT_DIR}/01_pods_wide.txt" 2>&1
  kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o json \
    > "${OUT_DIR}/02_pods.json" 2>&1
  kubectl get statefulsets,deployments,jobs -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${RELEASE}" -o wide \
    > "${OUT_DIR}/03_workloads.txt" 2>&1

  for pod in ${PODS}; do
    PHASE=$(kubectl get pod -n "${NAMESPACE}" "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "${PHASE}" != "Running" ]; then
      log "   pod ${pod} en fase ${PHASE}; solo se registran metadatos (sin exec)."
      continue
    fi
    CONTAINERS=$(kubectl get pod -n "${NAMESPACE}" "${pod}" \
                   -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    for container in ${CONTAINERS}; do
      log "   ${pod} / ${container}"
      capture_container "${pod}" "${container}" "${OUT_DIR}"
      if [ "${pattern}" = "dynamic-loader" ]; then
        capture_components_dynamic "${pod}" "${container}" "${OUT_DIR}"
      fi
    done
  done

  # ── Veredicto automático por patrón ──────────────────────────────────────
  {
    echo "## ${pattern}"
    echo
    echo "Pods y nodo de scheduling:"
    echo '```'
    cat "${OUT_DIR}/01_pods_wide.txt"
    echo '```'
    echo
    echo "Procesos que implementan nodos IA / host de composición"
    echo "(fuente: \`*__procwalk.txt\`; un PID por línea; si varios tokens comparten"
    echo "PID en el mismo contenedor, comparten proceso OS):"
    echo
    echo "| Token | Pod / contenedor | PID(s) |"
    echo "|---|---|---|"
    for token in ${NODE_TOKENS}; do
      found=0
      for f in "${OUT_DIR}"/*__procwalk.txt; do
        [ -e "$f" ] || continue
        base=$(basename "$f" __procwalk.txt)
        pids=$(grep -i -- "${token}" "$f" 2>/dev/null | cut -d'|' -f1 | sort -n | tr '\n' ' ')
        if [ -n "${pids// /}" ]; then
          echo "| ${token} | ${base/__/ / } | ${pids}|"
          found=1
        fi
      done
      [ "${found}" -eq 0 ] && echo "| ${token} | (no encontrado) | - |"
    done
    echo
    case "${pattern}" in
      dynamic-loader)
        echo "_Lectura esperada: un único proceso \`component_container\` aloja los 4"
        echo "nodos IA como componentes cargados (ver \`*__components.txt\`); los tokens"
        echo "de nodos individuales NO deben aparecer como procesos propios en el"
        echo "contenedor component-host._"
        ;;
      *)
        echo "_Lectura esperada: cada token de nodo IA aparece con un PID distinto"
        echo "(procesos OS separados, cada uno con su intérprete Python y su contexto CUDA)._"
        ;;
    esac
    echo
  } >> "${SUMMARY}"
done

log "Hecho. Resumen: ${SUMMARY}"
log "Artefactos por patrón en ${OUT_BASE}/<pattern>/${TS}/"
