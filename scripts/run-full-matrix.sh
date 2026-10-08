#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: run-full-matrix.sh [verify|steady|churn|concurrency|saturation|l4-attack|l7-spaghetti|all]

With no argument (or 'all'), run the existing full matrix.
With one suite, run only that suite across all applicable models.
L4 attack applies to L4 models; L7 spaghetti applies to L7 models.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  usage >&2
  exit 1
fi

SELECTED_SUITE="${1:-all}"
case "${SELECTED_SUITE}" in
  all|verify|steady|churn|concurrency|saturation|l4-attack|l7-spaghetti) ;;
  *) usage >&2; exit 1 ;;
esac

CLEANUP_AFTER_MODEL="${CLEANUP_AFTER_MODEL:-true}"
RUN_VERIFY="${RUN_VERIFY:-true}"
RUN_STEADY="${RUN_STEADY:-true}"
RUN_CHURN="${RUN_CHURN:-true}"
RUN_L4_ATTACK="${RUN_L4_ATTACK:-true}"
RUN_L7_SPAGHETTI="${RUN_L7_SPAGHETTI:-true}"

mapfile -t MODELS < <(all_models)

for model in "${MODELS[@]}"; do
  if [[ "${SELECTED_SUITE}" == "l4-attack" && "$(model_level "${model}")" != "l4" ]] || \
     [[ "${SELECTED_SUITE}" == "l7-spaghetti" && "$(model_level "${model}")" != "l7" ]]; then
    msg "Skipping ${model}: ${SELECTED_SUITE} does not apply"
    continue
  fi

  echo
  echo "============================================================"
  echo "MODEL: ${model}"
  echo "============================================================"

  bash "${ROOT_DIR}/scripts/up.sh" "${model}"

  if [[ "${SELECTED_SUITE}" != "all" ]]; then
    bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" "${SELECTED_SUITE}"
  else
    if [[ "${RUN_VERIFY}" == "true" ]]; then
      bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" verify
    fi
    if [[ "${RUN_STEADY}" == "true" ]]; then
      bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" steady
    fi
    if [[ "${RUN_CHURN}" == "true" ]]; then
      bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" churn
    fi
    if [[ "${RUN_L4_ATTACK}" == "true" && "$(model_level "${model}")" == "l4" ]]; then
      bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" l4-attack
    fi
    if [[ "${RUN_L7_SPAGHETTI}" == "true" && "$(model_level "${model}")" == "l7" ]]; then
      bash "${ROOT_DIR}/scripts/run-benchmark-suite.sh" "${model}" l7-spaghetti
    fi
  fi

  if [[ "${CLEANUP_AFTER_MODEL}" == "true" ]]; then
    bash "${ROOT_DIR}/scripts/down.sh" "${model}" hard
  fi
done

msg "Experimental matrix completed: ${SELECTED_SUITE}"
