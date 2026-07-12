#!/usr/bin/env bash
# BYOM template, dynamic loading pattern: build, push and deploy.
# Usage: export REG=<registry>/<project>; export TAG=mymodel-v1; bash deploy.sh
set -euo pipefail
REG="${REG:?export REG=<registry>/<project> first}"
TAG="${TAG:-mymodel-v1}"
NS="${NS:-ros2exp}"
cd "$(dirname "$0")/../.."

docker build --platform linux/arm64 \
  -f template/dynamic-loader/Dockerfile \
  -t "${REG}/ros2-component-host:${TAG}" .
docker push "${REG}/ros2-component-host:${TAG}"

helm upgrade --install dynamic-pattern Patterns/dynamic-loader/helm/dynamic-loader \
  -n "${NS}" --create-namespace --timeout 45m \
  --set image.repository="${REG}/ros2-component-host" \
  --set image.tag="${TAG}"

kubectl get pods -n "${NS}"
echo "OK: dynamic pattern deployed; your model is hot swappable as module 'yolo'."
echo "Try: bash template/dynamic-loader/hotswap_example.sh"
