#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 1 ]] || { echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"; exit 1; }
case "$1" in
  baseline|baseline-calico-ebpf) exec bash "${SCRIPT_DIR}/up-baseline.sh" ;;
  ambient-l4|istio-ambient-l4|l4) exec bash "${SCRIPT_DIR}/up-istio-ambient-l4.sh" ;;
  l7|l7-dikastes|istio-l7-dikastes) exec bash "${SCRIPT_DIR}/up-istio-l7-dikastes.sh" ;;
  *) echo "Unknown model: $1"; exit 1 ;;
esac
