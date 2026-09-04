#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CLEANUP_AFTER_MODEL="${CLEANUP_AFTER_MODEL:-true}"
RUN_VERIFY="${RUN_VERIFY:-true}"
RUN_STEADY="${RUN_STEADY:-true}"
RUN_CHURN="${RUN_CHURN:-true}"

mapfile -t MODELS < <(all_models)

for model in "${MODELS[@]}"; do
  echo
  echo "============================================================"
  echo "MODEL: ${model}"
  echo "============================================================"

  bash "${ROOT_DIR}/scripts/up.sh" "${model}"

  if [[ "${RUN_VERIFY}" == "true" ]]; then
    bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" verify
  fi
  if [[ "${RUN_STEADY}" == "true" ]]; then
    bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" steady
  fi
  if [[ "${RUN_CHURN}" == "true" ]]; then
    bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" churn
  fi

  if [[ "${CLEANUP_AFTER_MODEL}" == "true" ]]; then
    bash "${ROOT_DIR}/scripts/down.sh" "${model}" hard
  fi
done

msg "Current experimental matrix completed"
