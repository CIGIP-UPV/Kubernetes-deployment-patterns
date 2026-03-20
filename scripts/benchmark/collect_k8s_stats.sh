#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <namespace> <release> <duration_seconds> <output_csv>"
  exit 1
fi

NAMESPACE=$1
RELEASE=$2
DURATION=$3
OUTPUT=$4

mkdir -p "$(dirname "${OUTPUT}")"
echo "timestamp_unix,pod,cpu,memory" > "${OUTPUT}"

END=$(( $(date +%s) + DURATION ))
while [[ $(date +%s) -lt ${END} ]]; do
  TS=$(date +%s)
  kubectl top pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" --no-headers 2>/dev/null | \
    awk -v ts="${TS}" '{print ts","$1","$2","$3}' >> "${OUTPUT}" || true
  sleep 5
done
