#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes|cluster-name>"
  exit 1
fi

case "$1" in
  baseline|baseline-calico-ebpf|ambient-l4|istio-ambient-l4|l4|l7|l7-dikastes|istio-l7-dikastes|istio-sidecar-calico-l7-dikastes)
    CLUSTER_NAME="$(model_cluster "$1")"
    ;;
  *)
    CLUSTER_NAME="$1"
    ;;
esac

stop_model_port_forwards "${CLUSTER_NAME}" || true
stop_cluster "${CLUSTER_NAME}"
