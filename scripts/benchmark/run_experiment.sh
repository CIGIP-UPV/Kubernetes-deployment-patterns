#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <pattern> <scenario:S1|S2|S3> <duration_seconds> [namespace] [release] [registry_prefix] [tag]"
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PATTERN=$1
SCENARIO=$(echo "$2" | tr '[:lower:]' '[:upper:]')
DURATION=$3
NAMESPACE=${4:-ros2-bench}
RELEASE=${5:-${PATTERN,,}-${SCENARIO,,}-$(date +%H%M%S)}
REGISTRY_PREFIX=${6:-local}
TAG=${7:-latest}
SYNTHETIC_CAMERA=${BENCHMARK_SYNTHETIC_CAMERA:-false}
DEFAULT_ROS_DOMAIN_ID=$(( ($(printf '%s' "${RELEASE}" | cksum | awk '{print $1}') % 200) + 20 ))
ROS_DOMAIN_ID=${BENCHMARK_ROS_DOMAIN_ID:-${DEFAULT_ROS_DOMAIN_ID}}
RMW_IMPLEMENTATION=${BENCHMARK_RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}
PROBE_IMAGE=${BENCHMARK_PROBE_IMAGE:-${REGISTRY_PREFIX}/ros2-yolo:${TAG}}
PROBE_IMAGE_PULL_POLICY=${BENCHMARK_PROBE_IMAGE_PULL_POLICY:-IfNotPresent}
VALUES_FILE=${BENCHMARK_VALUES_FILE:-}
CLEANUP_RELEASE=${BENCHMARK_CLEANUP_RELEASE:-false}

case "${PATTERN}" in
  monolithic)
    CHART="${ROOT_DIR}/Patterns/monolithic/helm"
    IMAGE_SET=(
      --set "image.repository=${REGISTRY_PREFIX}/ros2-monolithic"
      --set "image.tag=${TAG}"
    )
    ;;
  microservices)
    CHART="${ROOT_DIR}/Patterns/microservices/helm/ros2-microservices"
    IMAGE_SET=(
      --set "images.camera.repository=${REGISTRY_PREFIX}/ros2-camera"
      --set "images.camera.tag=${TAG}"
      --set "images.yolo.repository=${REGISTRY_PREFIX}/ros2-yolo"
      --set "images.yolo.tag=${TAG}"
    )
    ;;
  dynamic-loader)
    CHART="${ROOT_DIR}/Patterns/dynamic-loader/helm/dynamic-loader"
    IMAGE_SET=(
      --set "images.camera.repository=${REGISTRY_PREFIX}/ros2-camera"
      --set "images.camera.tag=${TAG}"
      --set "images.dynamicHost.repository=${REGISTRY_PREFIX}/ros2-yolo"
      --set "images.dynamicHost.tag=${TAG}"
    )
    ;;
  overlay-workspaces)
    CHART="${ROOT_DIR}/Patterns/overlay-workspaces/helm/ros2-overlay"
    IMAGE_SET=(
      --set "image.repository=${REGISTRY_PREFIX}/ros2-overlay"
      --set "image.tag=${TAG}"
    )
    ;;
  *)
    echo "Unsupported pattern: ${PATTERN}"
    exit 1
    ;;
esac

case "${SCENARIO}" in
  S1) FPS=10 ;;
  S2) FPS=20 ;;
  S3) FPS=30 ;;
  *)
    echo "Unsupported scenario: ${SCENARIO} (use S1, S2 or S3)"
    exit 1
    ;;
esac

SCENARIO_SET=(
  --set "camera.fps=${FPS}"
  --set "ros.domainId=${ROS_DOMAIN_ID}"
  --set "ros.rmwImplementation=${RMW_IMPLEMENTATION}"
)
if [[ "${SYNTHETIC_CAMERA}" == "true" ]]; then
  SCENARIO_SET+=(--set "camera.syntheticMode=true" --set "camera.mountVideoDevice=false")
fi
if [[ "${PATTERN}" == "monolithic" || "${PATTERN}" == "overlay-workspaces" ]]; then
  SCENARIO_SET+=(--set "yolo.conf=0.25")
fi
if [[ "${PATTERN}" == "microservices" ]]; then
  SCENARIO_SET+=(--set "yolo.conf=0.25")
fi
if [[ "${PATTERN}" == "dynamic-loader" ]]; then
  SCENARIO_SET+=(--set "dynamic.conf=0.25")
fi

RESULT_DIR="${ROOT_DIR}/results/${RELEASE}"
mkdir -p "${RESULT_DIR}"

INSTALL_START=$(date +%s)
HELM_ARGS=(upgrade --install "${RELEASE}" "${CHART}" -n "${NAMESPACE}" --create-namespace)
if [[ -n "${VALUES_FILE}" ]]; then
  HELM_ARGS+=(-f "${VALUES_FILE}")
fi
HELM_ARGS+=("${IMAGE_SET[@]}" "${SCENARIO_SET[@]}")
helm "${HELM_ARGS[@]}"
INSTALL_END=$(date +%s)
INSTALL_SECONDS=$((INSTALL_END - INSTALL_START))

kubectl wait --for=condition=Ready pod -n "${NAMESPACE}" \
  -l "app.kubernetes.io/instance=${RELEASE}" --timeout=600s

"${ROOT_DIR}/scripts/benchmark/collect_k8s_stats.sh" \
  "${NAMESPACE}" "${RELEASE}" "${DURATION}" "${RESULT_DIR}/k8s_top.csv" &
TOP_PID=$!

PROBE_CM="${RELEASE}-probe-script"
PROBE_POD="${RELEASE}-probe"

kubectl -n "${NAMESPACE}" delete pod "${PROBE_POD}" --ignore-not-found >/dev/null
kubectl -n "${NAMESPACE}" delete configmap "${PROBE_CM}" --ignore-not-found >/dev/null
kubectl -n "${NAMESPACE}" create configmap "${PROBE_CM}" \
  --from-file=ros_latency_probe.py="${ROOT_DIR}/scripts/benchmark/ros_latency_probe.py" >/dev/null

cat <<YAML | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  labels:
    app.kubernetes.io/instance: ${RELEASE}
    app.kubernetes.io/name: ros-latency-probe
spec:
  restartPolicy: Never
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      imagePullPolicy: ${PROBE_IMAGE_PULL_POLICY}
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -e
          source /opt/ros/humble/setup.bash
          export ROS_DOMAIN_ID=${ROS_DOMAIN_ID}
          export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}
          export ROS_LOCALHOST_ONLY=0
          python3 /probe/ros_latency_probe.py \
            --latency-topic /benchmark/latency_ms \
            --inference-topic /benchmark/inference_ms \
            --duration ${DURATION} \
            --output-dir /tmp \
            --summary /tmp/summary.json
          touch /tmp/probe.done
          sleep 600
      volumeMounts:
        - name: probe-script
          mountPath: /probe
          readOnly: true
  volumes:
    - name: probe-script
      configMap:
        name: ${PROBE_CM}
YAML

kubectl wait -n "${NAMESPACE}" --for=condition=Ready "pod/${PROBE_POD}" --timeout=180s || true
PROBE_DEADLINE=$((SECONDS + DURATION + 180))
while (( SECONDS < PROBE_DEADLINE )); do
  if kubectl exec -n "${NAMESPACE}" "${PROBE_POD}" -- test -f /tmp/summary.json >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl logs -n "${NAMESPACE}" "${PROBE_POD}" > "${RESULT_DIR}/probe.log" || true
kubectl cp "${NAMESPACE}/${PROBE_POD}:/tmp/latency.csv" "${RESULT_DIR}/latency.csv" >/dev/null 2>&1 || true
kubectl cp "${NAMESPACE}/${PROBE_POD}:/tmp/inference.csv" "${RESULT_DIR}/inference.csv" >/dev/null 2>&1 || true
kubectl cp "${NAMESPACE}/${PROBE_POD}:/tmp/summary.json" "${RESULT_DIR}/summary.json" >/dev/null 2>&1 || true

if ps -p ${TOP_PID} >/dev/null 2>&1; then
  kill ${TOP_PID} >/dev/null 2>&1 || true
fi
wait ${TOP_PID} 2>/dev/null || true

READY_SECONDS=""
if [[ -f "${RESULT_DIR}/summary.json" ]]; then
  READY_SECONDS=$(python3 - <<PY
import json
from pathlib import Path
summary_path = Path("${RESULT_DIR}/summary.json")
install_end = ${INSTALL_END}
summary = json.loads(summary_path.read_text())
first = None
for key in ("latency", "inference"):
    section = summary.get(key, {})
    if isinstance(section, dict) and isinstance(section.get("first_sample_unix"), (int, float)):
        first = section["first_sample_unix"]
        break
if isinstance(first, (int, float)):
    print(max(0.0, first - install_end))
else:
    print("")
PY
)
fi

kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" -o wide > "${RESULT_DIR}/pods.txt" || true
helm get values "${RELEASE}" -n "${NAMESPACE}" > "${RESULT_DIR}/helm-values.yaml" || true

cat > "${RESULT_DIR}/metadata.json" <<JSON
{
  "pattern": "${PATTERN}",
  "scenario": "${SCENARIO}",
  "release": "${RELEASE}",
  "namespace": "${NAMESPACE}",
  "ros_domain_id": ${ROS_DOMAIN_ID},
  "duration_seconds": ${DURATION},
  "image_registry_prefix": "${REGISTRY_PREFIX}",
  "image_tag": "${TAG}",
  "install_seconds": ${INSTALL_SECONDS},
  "ready_seconds": "${READY_SECONDS}"
}
JSON

kubectl -n "${NAMESPACE}" delete pod "${PROBE_POD}" --ignore-not-found >/dev/null || true
kubectl -n "${NAMESPACE}" delete configmap "${PROBE_CM}" --ignore-not-found >/dev/null || true

if [[ "${CLEANUP_RELEASE}" == "true" ]]; then
  helm uninstall "${RELEASE}" -n "${NAMESPACE}" >/dev/null || true
fi

echo "[done] Results stored in ${RESULT_DIR}"
