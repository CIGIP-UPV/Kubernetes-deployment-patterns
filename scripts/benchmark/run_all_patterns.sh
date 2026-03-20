#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <scenario:S1|S2|S3> <duration_seconds> [namespace] [registry_prefix] [tag]"
  exit 1
fi

SCENARIO=$1
DURATION=$2
NAMESPACE=${3:-ros2-bench}
REGISTRY_PREFIX=${4:-local}
TAG=${5:-latest}

PATTERNS=(monolithic microservices dynamic-loader overlay-workspaces)

for pattern in "${PATTERNS[@]}"; do
  echo "===== Running ${pattern} (${SCENARIO}) ====="
  "$(dirname "${BASH_SOURCE[0]}")/run_experiment.sh" \
    "${pattern}" "${SCENARIO}" "${DURATION}" "${NAMESPACE}" "" "${REGISTRY_PREFIX}" "${TAG}"
done
