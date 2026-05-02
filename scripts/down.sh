#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes|all> [soft|hard]"
  echo "soft = stop cluster without deletion"
  echo "hard = delete cluster"
  exit 1
fi

TARGET="$1"
MODE="${2:-hard}"

handle_one() {
  local model="$1"
  local cluster_name
  cluster_name="$(model_cluster "${model}")"

  case "${MODE}" in
    soft)
      stop_model_port_forwards "${cluster_name}" || true
      stop_cluster "${cluster_name}"
      ;;
    hard)
      delete_cluster "${cluster_name}"
      ;;
    *)
      die "Unknown mode: ${MODE}. Use soft or hard"
      ;;
  esac
}

if [[ "${TARGET}" == "all" ]]; then
  handle_one baseline
  handle_one ambient-l4
  handle_one l7-dikastes
else
  handle_one "${TARGET}"
fi
