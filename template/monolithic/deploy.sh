#!/usr/bin/env bash
# BYOM template, monolithic pattern: build, push and deploy.
# Usage: export REG=<registry>/<project>; export TAG=mymodel-v1; bash deploy.sh
set -euo pipefail
REG="${REG:?export REG=<registry>/<project> first}"
TAG="${TAG:-mymodel-v1}"
NS="${NS:-ros2exp}"
cd "$(dirname "$0")/../.."

# The runtime pod runs on the arm64 edge node (Jetson).
docker build --platform linux/arm64 \
  -f template/monolithic/Dockerfile \
  -t "${REG}/ros2-monolithic:${TAG}" .
docker push "${REG}/ros2-monolithic:${TAG}"

helm upgrade --install monolithic-pattern Patterns/monolithic/helm \
  -n "${NS}" --create-namespace --timeout 45m \
  --set image.repository="${REG}/ros2-monolithic" \
  --set image.tag="${TAG}"

kubectl get pods -n "${NS}"
echo "OK: monolithic pattern deployed with your model in the perception slot."
