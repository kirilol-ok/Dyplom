#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
MODE="${1:-all}"
ACTION="${2:-stop}"
case "$MODE" in
  baseline|ambient-l4|l7-dikastes) CLUSTERS=("$(model_cluster "$MODE")") ;;
  all) CLUSTERS=(baseline-calico-ebpf istio-ambient-l4 istio-l7-dikastes) ;;
  *) echo "Usage: $0 <baseline|ambient-l4|l7-dikastes|all> [stop|delete]"; exit 1 ;;
esac
for cluster in "${CLUSTERS[@]}"; do
  case "$ACTION" in
    stop) stop_cluster "$cluster" ;;
    delete) delete_cluster "$cluster" ;;
    *) echo "Usage: $0 <baseline|ambient-l4|l7-dikastes|all> [stop|delete]"; exit 1 ;;
  esac
done
