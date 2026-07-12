#!/usr/bin/env bash
# BYOM template, overlay workspaces pattern: build, push and deploy.
# Usage: export REG=<registry>/<project>; export TAG=mymodel-v1; bash deploy.sh
set -euo pipefail
REG="${REG:?export REG=<registry>/<project> first}"
TAG="${TAG:-mymodel-v1}"
NS="${NS:-ros2exp}"
cd "$(dirname "$0")/../.."

# The carrier platform must be amd64 (it executes on the cloud node); the
# payload inside is arm64 (built by the builder stage for the edge).
docker build --platform linux/amd64 --provenance=false \
  -f template/overlay-workspaces/Dockerfile \
  -t "${REG}/ros2-overlay-pack:${TAG}" .
docker push "${REG}/ros2-overlay-pack:${TAG}"

helm upgrade --install overlay-pattern Patterns/overlay/helm/ros2-overlay \
  -n "${NS}" --create-namespace --timeout 45m \
  --set images.overlayPack.repository="${REG}/ros2-overlay-pack" \
  --set images.overlayPack.tag="${TAG}"

kubectl get pods -n "${NS}"
echo "OK: overlay pattern deployed; your model travels in the overlay layer."
