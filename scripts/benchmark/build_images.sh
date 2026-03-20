#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REGISTRY_PREFIX=${1:-local}
TAG=${2:-latest}
TORCH_VARIANT=${TORCH_VARIANT:-cpu}
BUILD_PLATFORM=${BUILD_PLATFORM:-}

build() {
  local image=$1
  local dockerfile=$2
  local context=$3
  echo "[build] ${image}:${TAG}"
  local args=(
    build
    --build-arg "TORCH_VARIANT=${TORCH_VARIANT}"
    -t "${REGISTRY_PREFIX}/${image}:${TAG}"
    -f "${ROOT_DIR}/${dockerfile}"
  )
  if [[ -n "${BUILD_PLATFORM}" ]]; then
    args+=(--platform "${BUILD_PLATFORM}")
  fi
  args+=("${ROOT_DIR}/${context}")
  docker "${args[@]}"
}

build "ros2-camera" "Models/ros2_cam_ws/docker/Dockerfile" "Models/ros2_cam_ws"
build "ros2-yolo" "Models/ros2_yolo_ws/docker/Dockerfile" "Models/ros2_yolo_ws"
build "ros2-monolithic" "Models/ros2_monolithic_ws/docker/Dockerfile" "."
build "ros2-overlay" "Models/ros2_overlay_ws/docker/Dockerfile" "."

echo "[done] Built images with prefix '${REGISTRY_PREFIX}', tag '${TAG}' and TORCH_VARIANT='${TORCH_VARIANT}'."
echo "If needed, push them to your registry before running Helm experiments."
