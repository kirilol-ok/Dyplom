#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CHURN_RATES="${CHURN_RATES:-100 200 300 400 500}"
REPEATS="${REPEATS:-3}"
BENCHMARK_VUS="${BENCHMARK_VUS:-400}"
CHURN_DURATION="${CHURN_DURATION:-45s}"
CHURN_COMPARE_REUSE="${CHURN_COMPARE_REUSE:-true}"
CHURN_INITIAL_SETTLE_SECONDS="${CHURN_INITIAL_SETTLE_SECONDS:-60}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
RESOURCE_CSV_ENABLED="${RESOURCE_CSV_ENABLED:-true}"

ACTIVE_MODEL=""

cleanup() {
  if [[ -n "${ACTIVE_MODEL}" ]]; then
    local cluster_name
    cluster_name="$(model_cluster "${ACTIVE_MODEL}")"
    if cluster_exists "${cluster_name}"; then
      warn "Cleaning up ${ACTIVE_MODEL} after interruption"
      delete_cluster "${cluster_name}" || true
    fi
  fi
}
trap cleanup EXIT INT TERM

for model in $(all_models); do
  ACTIVE_MODEL="${model}"
  cluster_name="$(model_cluster "${model}")"

  msg "============================================================"
  msg "Churn matrix: ${model}"
  msg "RPS: ${CHURN_RATES}; repeats: ${REPEATS}; VUs: ${BENCHMARK_VUS}"
  msg "============================================================"

  bash "${SCRIPT_DIR}/up.sh" "${model}"

  CHURN_RATES="${CHURN_RATES}" \
  REPEATS="${REPEATS}" \
  BENCHMARK_VUS="${BENCHMARK_VUS}" \
  CHURN_DURATION="${CHURN_DURATION}" \
  CHURN_COMPARE_REUSE="${CHURN_COMPARE_REUSE}" \
  CHURN_INITIAL_SETTLE_SECONDS="${CHURN_INITIAL_SETTLE_SECONDS}" \
  COOLDOWN_SECONDS="${COOLDOWN_SECONDS}" \
  RESOURCE_CSV_ENABLED="${RESOURCE_CSV_ENABLED}" \
    bash "${SCRIPT_DIR}/run-benchmark-suite.sh" "${model}" churn

  delete_cluster "${cluster_name}"
  ACTIVE_MODEL=""
done

msg "All six churn matrices finished"
