#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <model|all> [soft|hard]"
  exit 1
fi

SELECTOR="$1"
MODE="${2:-soft}"
[[ "${MODE}" == "soft" || "${MODE}" == "hard" ]] || die "Use soft or hard"

if [[ "${SELECTOR}" == "all" ]]; then
  mapfile -t MODELS < <(all_models)
else
  MODELS=("$(canonical_model "${SELECTOR}")")
fi

for model in "${MODELS[@]}"; do
  cluster="$(model_cluster "${model}")"
  if [[ "${MODE}" == "hard" ]]; then
    delete_cluster "${cluster}"
  else
    stop_cluster "${cluster}"
  fi
done
