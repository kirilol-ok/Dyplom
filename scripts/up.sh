#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <calico-baseline|calico-l4|calico-l7|ambient-baseline|ambient-l4|ambient-l7>"
  exit 1
fi

MODEL="$(canonical_model "$1")"
case "${MODEL}" in
  calico-baseline) exec bash "${SCRIPT_DIR}/up-calico-baseline.sh" ;;
  calico-l4) exec bash "${SCRIPT_DIR}/up-calico-l4.sh" ;;
  calico-l7) exec bash "${SCRIPT_DIR}/up-calico-l7-dikastes.sh" ;;
  ambient-baseline) exec bash "${SCRIPT_DIR}/up-ambient-baseline.sh" ;;
  ambient-l4) exec bash "${SCRIPT_DIR}/up-ambient-l4.sh" ;;
  ambient-l7) exec bash "${SCRIPT_DIR}/up-ambient-l7-waypoint.sh" ;;
esac
