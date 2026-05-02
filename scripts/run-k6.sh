#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> [script.js]"
  echo
  echo "Useful env vars:"
  echo "  VUS=20 DURATION=30s RPS=0 TEST_MODE=allowed PAYLOAD_SIZE=128 RESPONSE_SIZE=128"
  echo "  REQUEST_METHOD=GET REQUEST_PATH=/api/data NO_CONNECTION_REUSE=false SERVER_DELAY_MS=0"
  exit 1
fi

MODEL="$1"
K6_SCRIPT="${2:-loadtest.js}"
CLUSTER_NAME="$(model_cluster "${MODEL}")"
MODEL_SHORT="$(model_short "${MODEL}")"
APP_NS="${APP_NS:-test-app}"
K6_SCRIPT_PATH="${ROOT_DIR}/k6/${K6_SCRIPT}"

[[ -f "${K6_SCRIPT_PATH}" ]] || die "K6 script not found: ${K6_SCRIPT_PATH}"

JOB_NAME="${JOB_NAME:-k6-test}"
SCRIPT_TAG="${K6_SCRIPT%.js}"
VUS="${VUS:-$(get_k6_vus_from_script "${K6_SCRIPT_PATH}")}"
DURATION="${DURATION:-$(get_k6_duration_from_script "${K6_SCRIPT_PATH}")}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
RPS="${RPS:-0}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-128}"
RESPONSE_SIZE="${RESPONSE_SIZE:-128}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
REQUEST_PATH="${REQUEST_PATH:-/api/data}"
TEST_MODE="${TEST_MODE:-allowed}"
NO_CONNECTION_REUSE="${NO_CONNECTION_REUSE:-false}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-0}"
TIMEOUT="${TIMEOUT:-5s}"
SLEEP_MS="${SLEEP_MS:-100}"
FAIL_RATE_THRESHOLD="${FAIL_RATE_THRESHOLD:-0.05}"
P95_THRESHOLD_MS="${P95_THRESHOLD_MS:-1000}"
SUCCESS_RATE_THRESHOLD="${SUCCESS_RATE_THRESHOLD:-0.95}"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d-%H%M%S)}"
RESULT_PREFIX="$(build_result_prefix "${MODEL_SHORT}" "${SCRIPT_TAG}" "${VUS}" "${DURATION}" "${RUN_TAG}")"
LOG_FILE="${RESULT_PREFIX}.log"
SUMMARY_FILE="${RESULT_PREFIX}-summary.json"
RAW_FILE="${RESULT_PREFIX}-raw.json"

msg "Using model: ${MODEL_SHORT}"
msg "Cluster: ${CLUSTER_NAME}"
msg "Namespace: ${APP_NS}"
msg "K6 script: ${K6_SCRIPT}"
msg "VUS=${VUS}, DURATION=${DURATION}, RPS=${RPS}, MODE=${TEST_MODE}"
msg "Target: ${TARGET_URL}"
msg "Local result prefix: ${RESULT_PREFIX}"

check_base_tools
use_cluster "${CLUSTER_NAME}"
create_k6_configmap "${APP_NS}"

export VUS DURATION TARGET_URL RPS PAYLOAD_SIZE RESPONSE_SIZE REQUEST_METHOD REQUEST_PATH TEST_MODE
export K6_MODEL="${MODEL_SHORT}"
export NO_CONNECTION_REUSE SERVER_DELAY_MS TIMEOUT SLEEP_MS FAIL_RATE_THRESHOLD P95_THRESHOLD_MS SUCCESS_RATE_THRESHOLD

run_k6_job_manifest "${APP_NS}" "${JOB_NAME}" "${K6_SCRIPT}"

POD_NAME="$(wait_k6_pod_created "${APP_NS}" "${JOB_NAME}")"

msg "Waiting for k6 pod to start"

POD_NAME=""

for _ in $(seq 1 120); do
  POD_NAME="$(kubectl get pods -n "${APP_NS}" -l job-name="${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -n "${POD_NAME}" ]]; then
    break
  fi

  sleep 1
done

if [[ -z "${POD_NAME}" ]]; then
  warn "k6 pod was not created"
  kubectl get pods -n "${APP_NS}" -o wide || true
  kubectl get events -n "${APP_NS}" --sort-by='.lastTimestamp' | tail -40 || true
  exit 1
fi

msg "k6 pod created: ${POD_NAME}"

for _ in $(seq 1 180); do
  PHASE="$(kubectl get pod "${POD_NAME}" -n "${APP_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  WAITING_REASON="$(kubectl get pod "${POD_NAME}" -n "${APP_NS}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  TERMINATED_REASON="$(kubectl get pod "${POD_NAME}" -n "${APP_NS}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"

  if [[ "${PHASE}" == "Running" ]]; then
    msg "k6 pod is Running"
    break
  fi

  if [[ "${PHASE}" == "Succeeded" ]]; then
    msg "k6 pod already Succeeded"
    break
  fi

  if [[ "${PHASE}" == "Failed" ]]; then
    warn "k6 pod Failed"
    kubectl describe pod "${POD_NAME}" -n "${APP_NS}" || true
    kubectl logs "${POD_NAME}" -n "${APP_NS}" --all-containers=true || true
    exit 1
  fi

  if [[ -n "${WAITING_REASON}" ]]; then
    msg "k6 pod phase=${PHASE}, waiting=${WAITING_REASON}"
  elif [[ -n "${TERMINATED_REASON}" ]]; then
    msg "k6 pod phase=${PHASE}, terminated=${TERMINATED_REASON}"
  else
    msg "k6 pod phase=${PHASE}"
  fi

  sleep 2
done

PHASE="$(kubectl get pod "${POD_NAME}" -n "${APP_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

if [[ "${PHASE}" != "Running" && "${PHASE}" != "Succeeded" ]]; then
  warn "k6 pod did not start correctly"
  kubectl get pod "${POD_NAME}" -n "${APP_NS}" -o wide || true
  kubectl describe pod "${POD_NAME}" -n "${APP_NS}" || true
  kubectl logs "${POD_NAME}" -n "${APP_NS}" --all-containers=true || true
  kubectl get events -n "${APP_NS}" --sort-by='.lastTimestamp' | tail -40 || true
  exit 1
fi

mkdir -p "$(dirname "${LOG_FILE}")"
msg "Streaming logs to ${LOG_FILE}"
kubectl logs -n "${APP_NS}" -f "${POD_NAME}" --pod-running-timeout=180s | tee "${LOG_FILE}" &
LOGS_PID=$!

msg "Waiting for k6 result marker"
if wait_for_pod_file "${APP_NS}" "${POD_NAME}" "/results/.k6-finished" 900; then
  copy_k6_result_file_if_exists "${APP_NS}" "${POD_NAME}" "/results/summary.json" "${SUMMARY_FILE}" || true
  copy_k6_result_file_if_exists "${APP_NS}" "${POD_NAME}" "/results/k6-raw.json" "${RAW_FILE}" || true
  kubectl exec -n "${APP_NS}" "${POD_NAME}" -- sh -c 'touch /results/.copied' || true
else
  warn "Timed out waiting for /results/.k6-finished"
  kubectl exec -n "${APP_NS}" "${POD_NAME}" -- sh -c 'touch /results/.copied' || true
fi

msg "Waiting for job completion or failure"
if kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${APP_NS}" --timeout=120s >/dev/null 2>&1; then
  msg "Job reached Complete condition"
else
  warn "Job did not reach Complete, checking Failed condition"
  kubectl wait --for=condition=failed "job/${JOB_NAME}" -n "${APP_NS}" --timeout=60s >/dev/null 2>&1 || true
fi

wait "${LOGS_PID}" || true

mkdir -p "${TMP_DIR}"
echo "${SUMMARY_FILE}" > "${TMP_DIR}/last-summary-${MODEL_SHORT}.txt"
echo "${RESULT_PREFIX}" > "${TMP_DIR}/last-prefix-${MODEL_SHORT}.txt"

echo
msg "Saved local files:"
[[ -f "${LOG_FILE}" ]] && echo "  ${LOG_FILE}"
[[ -f "${SUMMARY_FILE}" ]] && echo "  ${SUMMARY_FILE}"
[[ -f "${RAW_FILE}" ]] && echo "  ${RAW_FILE}"

echo
msg "Final job status:"
kubectl get job "${JOB_NAME}" -n "${APP_NS}" || true

echo
msg "Pods created by k6 job:"
kubectl get pods -n "${APP_NS}" -l job-name="${JOB_NAME}" || true

if [[ -f "${SUMMARY_FILE}" ]]; then
  echo
  msg "Pretty summary table:"
  python3 "${ROOT_DIR}/scripts/pretty-summary.py" "${SUMMARY_FILE}"
else
  warn "Summary file not found locally: ${SUMMARY_FILE}"
  exit 1
fi
