#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <registry_prefix> <tag> [namespace] [duration_seconds] [repetitions]"
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REGISTRY_PREFIX=$1
TAG=$2
NAMESPACE=${3:-ros2exp}
DURATION=${4:-300}
REPETITIONS=${5:-10}
CAMPAIGN_ID=${CAMPAIGN_ID:-$(date +%Y%m%d-%H%M%S)}
SYNTHETIC_CAMERA=${BENCHMARK_SYNTHETIC_CAMERA:-false}

SCENARIOS=(S1 S2 S3)
PATTERNS=(monolithic microservices dynamic-loader overlay-workspaces)

# Optional: override values per pattern (e.g., values-cloud-edge.yaml)
# If the file does not exist, only default values.yaml is used.
pattern_values_file() {
  local candidate=""
  case "$1" in
    monolithic)
      candidate="${ROOT_DIR}/Patterns/monolithic/helm/values-production.yaml"
      ;;
    microservices)
      candidate="${ROOT_DIR}/Patterns/microservices/helm/ros2-microservices/values-production.yaml"
      ;;
    dynamic-loader)
      candidate="${ROOT_DIR}/Patterns/dynamic-loader/helm/dynamic-loader/values-production.yaml"
      ;;
    overlay-workspaces)
      candidate="${ROOT_DIR}/Patterns/overlay-workspaces/helm/ros2-overlay/values-production.yaml"
      ;;
    *)
      echo "Unsupported pattern: $1" >&2
      exit 1
      ;;
  esac
  # Return path only if file exists; empty otherwise
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
  else
    echo ""
  fi
}

pattern_short_name() {
  case "$1" in
    monolithic) echo "mono" ;;
    microservices) echo "micro" ;;
    dynamic-loader) echo "dyn" ;;
    overlay-workspaces) echo "overlay" ;;
    *)
      echo "Unsupported pattern: $1" >&2
      exit 1
      ;;
  esac
}

for repetition in $(seq 1 "${REPETITIONS}"); do
  for scenario in "${SCENARIOS[@]}"; do
    for pattern in "${PATTERNS[@]}"; do
      release="$(pattern_short_name "${pattern}")-${scenario,,}-r${repetition}-${CAMPAIGN_ID}"
      values_file=$(pattern_values_file "${pattern}")

      echo "===== ${pattern} ${scenario} rep=${repetition}/${REPETITIONS} release=${release} ====="
      BENCHMARK_VALUES_FILE="${values_file}" \
      BENCHMARK_CLEANUP_RELEASE=true \
      BENCHMARK_SYNTHETIC_CAMERA="${SYNTHETIC_CAMERA}" \
      "${ROOT_DIR}/scripts/benchmark/run_experiment.sh" \
        "${pattern}" "${scenario}" "${DURATION}" "${NAMESPACE}" "${release}" "${REGISTRY_PREFIX}" "${TAG}"
    done
  done
done

echo "[done] Campaign '${CAMPAIGN_ID}' finished."
