#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> <output-prefix> [interval-seconds]"
  exit 1
fi

MODEL="$1"
OUTPUT_PREFIX="$2"
INTERVAL="${3:-${SAMPLE_INTERVAL:-5}}"
RESOURCE_NAMESPACES="${RESOURCE_NAMESPACES:-test-app istio-system calico-system}"

use_cluster "$(model_cluster "${MODEL}")"
mkdir -p "$(dirname "${OUTPUT_PREFIX}")"

CONTAINER_FILE="${OUTPUT_PREFIX}-containers.csv"
NODE_FILE="${OUTPUT_PREFIX}-nodes.csv"

echo "timestamp,model,namespace,pod,container,cpu_raw,cpu_millicores,memory_raw,memory_mib" > "${CONTAINER_FILE}"
echo "timestamp,model,node,cpu_raw,cpu_millicores,memory_raw,memory_mib" > "${NODE_FILE}"

cpu_to_millicores() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /n$/) { sub(/n$/, "", value); printf "%.6f", value / 1000000; }
    else if (value ~ /u$/) { sub(/u$/, "", value); printf "%.6f", value / 1000; }
    else if (value ~ /m$/) { sub(/m$/, "", value); printf "%.6f", value; }
    else { printf "%.6f", value * 1000; }
  }'
}

memory_to_mib() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /Ki$/) { sub(/Ki$/, "", value); printf "%.6f", value / 1024; }
    else if (value ~ /Mi$/) { sub(/Mi$/, "", value); printf "%.6f", value; }
    else if (value ~ /Gi$/) { sub(/Gi$/, "", value); printf "%.6f", value * 1024; }
    else if (value ~ /Ti$/) { sub(/Ti$/, "", value); printf "%.6f", value * 1048576; }
    else if (value ~ /K$/) { sub(/K$/, "", value); printf "%.6f", value / 1024 / 1024; }
    else if (value ~ /M$/) { sub(/M$/, "", value); printf "%.6f", value / 1024; }
    else if (value ~ /G$/) { sub(/G$/, "", value); printf "%.6f", value; }
    else { printf "%.6f", value / 1024 / 1024; }
  }'
}

stop=0
trap 'stop=1' INT TERM

while (( stop == 0 )); do
  timestamp="$(date -Iseconds)"

  for namespace in ${RESOURCE_NAMESPACES}; do
    while read -r pod container cpu memory; do
      [[ -n "${pod:-}" ]] || continue
      echo "${timestamp},${MODEL},${namespace},${pod},${container},${cpu},$(cpu_to_millicores "${cpu}"),${memory},$(memory_to_mib "${memory}")" >> "${CONTAINER_FILE}"
    done < <(kubectl top pods -n "${namespace}" --containers --no-headers 2>/dev/null || true)
  done

  while read -r node cpu cpu_percent memory memory_percent; do
    [[ -n "${node:-}" ]] || continue
    echo "${timestamp},${MODEL},${node},${cpu},$(cpu_to_millicores "${cpu}"),${memory},$(memory_to_mib "${memory}")" >> "${NODE_FILE}"
  done < <(kubectl top nodes --no-headers 2>/dev/null || true)

  sleep "${INTERVAL}" &
  wait $! || true
done
