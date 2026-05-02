#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> [start|stop]"
  exit 1
fi

MODEL="$1"
ACTION="${2:-start}"
CLUSTER_NAME="$(model_cluster "${MODEL}")"
use_cluster "${CLUSTER_NAME}"

case "${ACTION}" in
  start)
    start_monitoring_port_forwards "${CLUSTER_NAME}"
    ;;
  stop)
    stop_model_port_forwards "${CLUSTER_NAME}"
    ;;
  *)
    die "Unknown action: ${ACTION}. Use start or stop"
    ;;
esac
