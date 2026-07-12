#!/usr/bin/env bash
# BYOM template, microservices pattern: build, push and deploy.
# Usage: export REG=<registry>/<project>; export TAG=mymodel-v1; bash deploy.sh
set -euo pipefail
REG="${REG:?export REG=<registry>/<project> first}"
TAG="${TAG:-mymodel-v1}"
NS="${NS:-ros2exp}"
cd "$(dirname "$0")/../.."

docker build --platform linux/arm64 \
  -f template/microservices/Dockerfile \
  -t "${REG}/ros2-yolo:${TAG}" .
docker push "${REG}/ros2-yolo:${TAG}"

helm upgrade --install microservices-pattern Patterns/microservices/helm/ros2-microservices \
  -n "${NS}" --create-namespace --timeout 45m \
  --set images.yolo.repository="${REG}/ros2-yolo" \
  --set images.yolo.tag="${TAG}"

kubectl get pods -n "${NS}"
echo "OK: microservices pattern deployed; only the perception pod runs your model."
