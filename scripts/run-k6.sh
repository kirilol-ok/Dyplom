#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <model> [k6-script.js]"
  exit 1
fi

MODEL="$(canonical_model "$1")"
K6_SCRIPT="${2:-steady-rps.js}"
CLUSTER_NAME="$(model_cluster "${MODEL}")"
K6_SCRIPT_PATH="${ROOT_DIR}/k6/${K6_SCRIPT}"

[[ -f "${K6_SCRIPT_PATH}" ]] || die "K6 script not found: ${K6_SCRIPT_PATH}"
cluster_exists "${CLUSTER_NAME}" || die "Cluster does not exist: ${CLUSTER_NAME}. Run scripts/up.sh ${MODEL} first"

TARGET_MODE="${TARGET_MODE:-direct}"
TARGET_URL="${TARGET_URL:-http://server:8080}"
VUS="${VUS:-300}"
DURATION="${DURATION:-45s}"
RPS="${RPS:-0}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-128}"
RESPONSE_SIZE="${RESPONSE_SIZE:-128}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
REQUEST_PATH="${REQUEST_PATH:-/api/data}"
TEST_MODE="${TEST_MODE:-allowed}"
NO_CONNECTION_REUSE="${NO_CONNECTION_REUSE:-false}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-0}"
TIMEOUT="${TIMEOUT:-5s}"
SLEEP_MS="${SLEEP_MS:-0}"
RESOURCE_CSV_ENABLED="${RESOURCE_CSV_ENABLED:-true}"
RESOURCE_SAMPLE_SECONDS="${RESOURCE_SAMPLE_SECONDS:-2}"
RUN_TAG="${RUN_TAG:-run}"
PROFILE="${K6_SCRIPT%.js}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${STAMP}-${MODEL}-${PROFILE}-${RUN_TAG}-rps${RPS}-vus${VUS}-dur${DURATION}-reuse${NO_CONNECTION_REUSE}"
RUN_ID="${RUN_ID//\//_}"
RESULT_DIR="${RESULTS_DIR}/${MODEL}"
RESULT_PREFIX="${RESULT_DIR}/${RUN_ID}"
LOG_FILE="${RESULT_PREFIX}.log"
SUMMARY_FILE="${RESULT_PREFIX}-summary.json"
RAW_FILE="${RESULT_PREFIX}-raw.json"
RESOURCE_FILE="${RESULT_PREFIX}-resources.csv"
RESOURCE_SUMMARY_FILE="${RESULT_PREFIX}-resource-summary.csv"
JOB_NAME="k6-${STAMP,,}-$RANDOM"
JOB_NAME="${JOB_NAME:0:62}"
RENDERED_JOB="${TMP_DIR}/${JOB_NAME}.yaml"

mkdir -p "${RESULT_DIR}"

check_base_tools
use_cluster "${CLUSTER_NAME}"
create_k6_configmap

if [[ "${RESOURCE_CSV_ENABLED}" == "true" ]]; then
  msg "Checking Kubernetes Metrics API for CPU/RAM collection"
  if ! wait_metrics_api 90; then
    warn "Metrics API is not ready. The benchmark will continue, but the resource CSV may be empty."
  fi
fi

export K6_MODEL="${MODEL}"
export VUS DURATION TARGET_URL TARGET_MODE RPS PAYLOAD_SIZE RESPONSE_SIZE REQUEST_METHOD REQUEST_PATH
export TEST_MODE NO_CONNECTION_REUSE SERVER_DELAY_MS TIMEOUT SLEEP_MS

render_k6_job "${JOB_NAME}" "${K6_SCRIPT}" "${RENDERED_JOB}"

msg "Model: ${MODEL}"
msg "Cluster: ${CLUSTER_NAME}"
msg "Script: ${K6_SCRIPT}"
msg "Target: ${TARGET_URL}${REQUEST_PATH}"
msg "RPS=${RPS}, VUS=${VUS}, DURATION=${DURATION}, mode=${TEST_MODE}, noConnectionReuse=${NO_CONNECTION_REUSE}"
msg "Run ID: ${RUN_ID}"

kubectl apply -f "${RENDERED_JOB}" >/dev/null
POD_NAME="$(wait_k6_pod_created "${APP_NS}" "${JOB_NAME}" || true)"
[[ -n "${POD_NAME}" ]] || die "k6 pod was not created"

if ! wait_pod_running_or_done "${APP_NS}" "${POD_NAME}"; then
  kubectl describe pod "${POD_NAME}" -n "${APP_NS}" || true
  kubectl logs "${POD_NAME}" -n "${APP_NS}" --all-containers=true || true
  die "k6 pod failed to start"
fi

RESOURCE_PID=""
if [[ "${RESOURCE_CSV_ENABLED}" == "true" ]]; then
  msg "Starting CPU/RAM collector: ${RESOURCE_FILE}"
  python3 "${ROOT_DIR}/scripts/collect-resources.py" \
    --output "${RESOURCE_FILE}" \
    --interval "${RESOURCE_SAMPLE_SECONDS}" &
  RESOURCE_PID=$!
fi

msg "Streaming k6 logs to ${LOG_FILE}"
kubectl logs -n "${APP_NS}" -f "${POD_NAME}" -c k6 --pod-running-timeout=180s | tee "${LOG_FILE}" &
LOGS_PID=$!

if wait_for_pod_file "${APP_NS}" "${POD_NAME}" /results/.k6-finished 1200; then
  copy_pod_file "${APP_NS}" "${POD_NAME}" /results/summary.json "${SUMMARY_FILE}" || true
  copy_pod_file "${APP_NS}" "${POD_NAME}" /results/k6-raw.json "${RAW_FILE}" || true
  kubectl exec -n "${APP_NS}" "${POD_NAME}" -c k6 -- sh -c "touch /results/.copied" || true
else
  warn "Timed out waiting for k6 result marker"
  kubectl exec -n "${APP_NS}" "${POD_NAME}" -c k6 -- sh -c "touch /results/.copied" || true
fi

if [[ -n "${RESOURCE_PID}" ]]; then
  kill "${RESOURCE_PID}" >/dev/null 2>&1 || true
  wait "${RESOURCE_PID}" 2>/dev/null || true
fi

kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${APP_NS}" --timeout=120s >/dev/null 2>&1 \
  || kubectl wait --for=condition=failed "job/${JOB_NAME}" -n "${APP_NS}" --timeout=60s >/dev/null 2>&1 \
  || true
wait "${LOGS_PID}" 2>/dev/null || true

if [[ ! -f "${SUMMARY_FILE}" ]]; then
  kubectl get job "${JOB_NAME}" -n "${APP_NS}" || true
  kubectl describe pod "${POD_NAME}" -n "${APP_NS}" || true
  die "Summary file was not collected"
fi

python3 "${ROOT_DIR}/scripts/summary-to-csv.py" \
  "${SUMMARY_FILE}" \
  "${RESULTS_DIR}/benchmark-summary.csv" \
  --run-id "${RUN_ID}"

if [[ "${RESOURCE_CSV_ENABLED}" == "true" && -f "${RESOURCE_FILE}" ]]; then
  python3 "${ROOT_DIR}/scripts/summarize-resources.py" \
    "${RESOURCE_FILE}" \
    "${RESOURCE_SUMMARY_FILE}" \
    --master "${RESULTS_DIR}/benchmark-resources.csv" \
    --run-id "${RUN_ID}" \
    --model "${MODEL}" \
    --profile "${PROFILE}" \
    --rps "${RPS}" \
    --no-connection-reuse "${NO_CONNECTION_REUSE}"
fi

echo
python3 "${ROOT_DIR}/scripts/pretty-summary.py" "${SUMMARY_FILE}"
echo
msg "Saved:"
echo "  ${LOG_FILE}"
echo "  ${SUMMARY_FILE}"
[[ -f "${RAW_FILE}" ]] && echo "  ${RAW_FILE}"
[[ -f "${RESOURCE_FILE}" ]] && echo "  ${RESOURCE_FILE}"
[[ -f "${RESOURCE_SUMMARY_FILE}" ]] && echo "  ${RESOURCE_SUMMARY_FILE}"
