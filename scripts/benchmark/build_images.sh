#!/usr/bin/env bash
# =============================================================================
# build_images.sh — Build and (optionally) push all ROS 2 pattern images
# =============================================================================
# Usage:
#   ./scripts/benchmark/build_images.sh [REGISTRY_PREFIX] [TAG] [--push]
#
#   REGISTRY_PREFIX defaults to gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
#   TAG defaults to "latest"
#
#   --push uses `docker buildx --push` to publish directly to the registry
#          (recommended for large images to avoid `--load` hangs on macOS).
#          Without --push, images are loaded into the local Docker daemon.
#
# Per-image platform strategy:
#
#   Most images (the heavy ML ones) target ONLY linux/arm64 because they
#   contain the Jetson PyTorch wheel + L4T CUDA libraries, and they always
#   run on edgenode01 (the Jetson Orin). Building them as multi-arch would
#   double build time for zero runtime benefit.
#
#   Two images need multi-arch (linux/amd64,linux/arm64):
#     - ros2-overlay-pack: carrier executes on cloud node (kb2/amd64) for
#       the pre-install Job that copies /opt/overlay/ to the PVC. Contents
#       are arm64 but travel as opaque bytes inside a tarball, so the
#       multi-arch carrier is enough.
#     - ros2-dashboard: rosbridge + nginx, runs on cloud node.
#
# Set BUILD_PLATFORM=linux/amd64,linux/arm64 to force multi-arch on ALL
# images (rarely needed; most builds are arm64-only).
# =============================================================================
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REGISTRY_PREFIX=${1:-gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes}
TAG=${2:-latest}
TORCH_VARIANT=${TORCH_VARIANT:-auto}

# --push optionally publishes directly. Detect by scanning all args.
PUSH=""
for arg in "$@"; do
  if [ "$arg" = "--push" ]; then PUSH="--push"; fi
done

# Default platforms per image type
ARM64_ONLY="linux/arm64"
MULTI_ARCH="linux/amd64,linux/arm64"

# Allow global override
if [[ -n "${BUILD_PLATFORM:-}" ]]; then
  ARM64_ONLY="${BUILD_PLATFORM}"
  MULTI_ARCH="${BUILD_PLATFORM}"
fi

build() {
  local image=$1
  local dockerfile=$2
  local context=$3
  local platforms=$4
  local needs_secret=${5:-no}
  echo ""
  echo "============================================================"
  echo "[build] ${image}:${TAG}  platform=${platforms}"
  echo "============================================================"

  local args=(
    buildx build
    --platform "${platforms}"
    --build-arg "TORCH_VARIANT=${TORCH_VARIANT}"
    -t "${REGISTRY_PREFIX}/${image}:${TAG}"
    -f "${ROOT_DIR}/${dockerfile}"
    --provenance=false
  )

  if [ "${needs_secret}" = "yes" ]; then
    if [ -z "${HF_TOKEN:-}" ]; then
      echo "ERROR: ${image} needs HF_TOKEN env var (gated HuggingFace model)."
      echo "Export it first: export HF_TOKEN=hf_..."
      exit 1
    fi
    args+=(--secret id=hf_token,env=HF_TOKEN)
  fi

  if [ -n "${PUSH}" ]; then
    args+=(--push)
  else
    args+=(--load)
  fi

  args+=("${ROOT_DIR}/${context}")
  DOCKER_BUILDKIT=1 docker "${args[@]}"
}

# ── Edge images (arm64-only, run on Jetson) ─────────────────────────────────
build "ros2-camera"         "Models/ros2_cam_ws/docker/Dockerfile"         "Models/ros2_cam_ws" "${ARM64_ONLY}"  no
build "ros2-yolo"           "Models/ros2_yolo_ws/docker/Dockerfile"        "."                  "${ARM64_ONLY}"  no
build "ros2-llava"          "Models/ros2_llava_ws/docker/Dockerfile"       "."                  "${ARM64_ONLY}"  no
build "ros2-voxtral"        "Models/ros2_voxtral_ws/docker/Dockerfile"     "."                  "${ARM64_ONLY}"  yes
build "ros2-monolithic"     "Models/ros2_monolithic_ws/docker/Dockerfile"  "."                  "${ARM64_ONLY}"  yes

# Canonical pattern images (edge-only, arm64)
build "ros2-base"           "Models/ros2_base/docker/Dockerfile"           "."                  "${ARM64_ONLY}"  no
build "ros2-component-host" "Models/ros2_component_host/docker/Dockerfile" "."                  "${ARM64_ONLY}"  yes

# ── Multi-arch images (run on cloud node = amd64) ───────────────────────────
# overlay-pack: carrier role runs on cloud, contents are arm64 (but opaque
# inside the tarball, so multi-arch base is enough).
build "ros2-overlay-pack"   "Models/ros2_overlay_pack/docker/Dockerfile"   "."                  "${MULTI_ARCH}"  yes

# dashboard: rosbridge + nginx, runs on cloud (kb2 amd64). Already multi-arch.
build "ros2-dashboard"      "Models/ros2_dashboard/docker/Dockerfile"      "Models/ros2_dashboard" "${MULTI_ARCH}" no

echo ""
echo "============================================================"
echo "[done] Built images with prefix '${REGISTRY_PREFIX}', tag '${TAG}'."
if [ -n "${PUSH}" ]; then
  echo "Images were pushed to the registry."
else
  echo "Run again with --push to publish, or use 'docker push' manually."
fi
echo "============================================================"
