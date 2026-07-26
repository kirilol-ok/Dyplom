#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"
  exit 1
fi

MODEL="$1"
MODEL_SHORT="$(model_short "${MODEL}")"
CLUSTER="$(model_cluster "${MODEL}")"
APP_NAMESPACE="${APP_NAMESPACE:-${APP_NS}}"
SERVER_DEPLOYMENT="${SERVER_DEPLOYMENT:-server}"
REPLICAS_LIST="${REPLICAS_LIST:-1 5 10}"
RPS="${RPS:-200}"
DURATION="${DURATION:-2m}"
BENCHMARK_VUS="${BENCHMARK_VUS:-200}"
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"

use_cluster "${CLUSTER}"

original_replicas="$(kubectl get deployment "${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" -o jsonpath='{.spec.replicas}')"
RESULT_DIR="${RESULTS_DIR}/${MODEL_SHORT}/resource-scaling"
mkdir -p "${RESULT_DIR}"
ROLLOUT_FILE="${RESULT_DIR}/rollout-times.csv"

if [[ ! -f "${ROLLOUT_FILE}" ]]; then
  echo "timestamp,model,replicas,rollout_seconds" > "${ROLLOUT_FILE}"
fi

collector_pid=""

cleanup() {
  if [[ -n "${collector_pid}" ]] && kill -0 "${collector_pid}" >/dev/null 2>&1; then
    kill "${collector_pid}" >/dev/null 2>&1 || true
    wait "${collector_pid}" 2>/dev/null || true
  fi

  kubectl scale deployment "${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" --replicas="${original_replicas}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for replicas in ${REPLICAS_LIST}; do
  msg "Scaling ${SERVER_DEPLOYMENT} to ${replicas} replicas"
  rollout_start="$(date +%s)"
  kubectl scale deployment "${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" --replicas="${replicas}"
  kubectl rollout status deployment/"${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" --timeout=600s
  rollout_end="$(date +%s)"
  echo "$(date -Iseconds),${MODEL},${replicas},$((rollout_end - rollout_start))" >> "${ROLLOUT_FILE}"

  sleep "${SETTLE_SECONDS}"

  run_tag="$(date +%Y%m%d-%H%M%S)-replicas${replicas}"
  output_prefix="${RESULT_DIR}/${run_tag}"

  SAMPLE_INTERVAL="${SAMPLE_INTERVAL}" \
    bash "${ROOT_DIR}/scripts/collect-k8s-resources.sh" \
      "${MODEL}" "${output_prefix}" "${SAMPLE_INTERVAL}" &
  collector_pid=$!

  if ! env \
    MODEL="${MODEL}" \
    RUN_TAG="resource-replicas${replicas}" \
    VUS="${BENCHMARK_VUS}" \
    RPS="${RPS}" \
    DURATION="${DURATION}" \
    TARGET_URL="${TARGET_URL}" \
    TEST_MODE=allowed \
    SLEEP_MS=0 \
    bash "${ROOT_DIR}/scripts/run-k6.sh" "${MODEL}" steady-rps.js; then
    warn "The k6 run failed a threshold for replicas=${replicas}"
  fi

  kill "${collector_pid}" >/dev/null 2>&1 || true
  wait "${collector_pid}" 2>/dev/null || true
  collector_pid=""

done

msg "Resource scaling test finished"
