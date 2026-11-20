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
VUS="${VUS:-100}"
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
ALLOWED_RPS="${ALLOWED_RPS:-0}"
BLOCKED_RPS="${BLOCKED_RPS:-0}"
BLOCKED_TARGET_URL="${BLOCKED_TARGET_URL:-http://server:8081}"
BLOCKED_METHOD="${BLOCKED_METHOD:-GET}"
BLOCKED_PATH="${BLOCKED_PATH:-/health}"
SCENARIO_VARIANT="${SCENARIO_VARIANT:-default}"
RESOURCE_CSV_ENABLED="${RESOURCE_CSV_ENABLED:-true}"
RESOURCE_SAMPLE_SECONDS="${RESOURCE_SAMPLE_SECONDS:-2}"
RUN_TAG="${RUN_TAG:-run}"
PROFILE="${K6_SCRIPT%.js}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${STAMP}-${MODEL}-${PROFILE}-${RUN_TAG}-rps${RPS}-vus${VUS}-dur${DURATION}-reuse${NO_CONNECTION_REUSE}"
RUN_ID="${RUN_ID//\//_}"
RUN_TMP_DIR="$(mktemp -d "${TMP_DIR}/${RUN_ID}.XXXXXX")"
SUMMARY_FILE="${RUN_TMP_DIR}/summary.json"
RESOURCE_FILE="${RUN_TMP_DIR}/resources.csv"
METADATA_FILE="${RUN_TMP_DIR}/metadata.json"
JOB_NAME="k6-${STAMP,,}-$RANDOM"
JOB_NAME="${JOB_NAME:0:62}"
RENDERED_JOB="${RUN_TMP_DIR}/${JOB_NAME}.yaml"

RESOURCE_PID=""
LOGS_PID=""
JOB_CREATED=false

cleanup() {
  if [[ -n "${RESOURCE_PID}" ]]; then
    kill "${RESOURCE_PID}" >/dev/null 2>&1 || true
    wait "${RESOURCE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${LOGS_PID}" ]]; then
    kill "${LOGS_PID}" >/dev/null 2>&1 || true
    wait "${LOGS_PID}" 2>/dev/null || true
  fi
  if [[ "${JOB_CREATED}" == "true" ]]; then
    kubectl delete job "${JOB_NAME}" -n "${APP_NS}" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [[ -n "${RUN_TMP_DIR}" && "${RUN_TMP_DIR}" == "${TMP_DIR}/"* ]]; then
    rm -rf -- "${RUN_TMP_DIR}"
  fi
}
trap cleanup EXIT

check_base_tools
use_cluster "${CLUSTER_NAME}"
create_k6_configmap

if [[ "${RESOURCE_CSV_ENABLED}" == "true" ]]; then
  msg "Checking Kubernetes Metrics API for CPU/RAM collection"
  if ! wait_metrics_api 90; then
    warn "Metrics API is not ready. The benchmark will continue, but the resource CSV may have no rows for this run."
  fi
fi

export K6_MODEL="${MODEL}"
export VUS DURATION TARGET_URL TARGET_MODE RPS PAYLOAD_SIZE RESPONSE_SIZE REQUEST_METHOD REQUEST_PATH
export TEST_MODE NO_CONNECTION_REUSE SERVER_DELAY_MS TIMEOUT SLEEP_MS
export ALLOWED_RPS BLOCKED_RPS BLOCKED_TARGET_URL BLOCKED_METHOD BLOCKED_PATH SCENARIO_VARIANT

render_k6_job "${JOB_NAME}" "${K6_SCRIPT}" "${RENDERED_JOB}"

msg "Model: ${MODEL}"
msg "Cluster: ${CLUSTER_NAME}"
msg "Script: ${K6_SCRIPT}"
msg "Target: ${TARGET_URL}${REQUEST_PATH}"
msg "RPS=${RPS}, VUS=${VUS}, DURATION=${DURATION}, mode=${TEST_MODE}, noConnectionReuse=${NO_CONNECTION_REUSE}"
if (( ALLOWED_RPS > 0 || BLOCKED_RPS > 0 )); then
  msg "Traffic split: allowed=${ALLOWED_RPS} RPS, blocked=${BLOCKED_RPS} RPS, variant=${SCENARIO_VARIANT}"
fi
msg "Run ID: ${RUN_ID}"

kubectl apply -f "${RENDERED_JOB}" >/dev/null
JOB_CREATED=true
POD_NAME="$(wait_k6_pod_created "${APP_NS}" "${JOB_NAME}" || true)"
[[ -n "${POD_NAME}" ]] || die "k6 pod was not created"

if ! wait_pod_running_or_done "${APP_NS}" "${POD_NAME}"; then
  kubectl describe pod "${POD_NAME}" -n "${APP_NS}" || true
  kubectl logs "${POD_NAME}" -n "${APP_NS}" --all-containers=true || true
  die "k6 pod failed to start"
fi

# Wait until the k6 process is held at the explicit start gate.
if ! wait_for_pod_file "${APP_NS}" "${POD_NAME}" /results/.k6-ready 120; then
  die "k6 pod did not reach the benchmark start gate"
fi

python3 "${ROOT_DIR}/scripts/benchmark-metadata.py" \
  --output "${METADATA_FILE}" \
  --archive-dir "${RESULTS_DIR}/benchmark-configs" \
  --repo-root "${ROOT_DIR}" \
  --namespace "${APP_NS}" \
  --script "${K6_SCRIPT_PATH}" \
  --job-name "${JOB_NAME}" --k6-pod "${POD_NAME}"
CONFIG_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["config_id"])' "${METADATA_FILE}")"

if [[ "${RESOURCE_CSV_ENABLED}" == "true" ]]; then
  msg "Starting CPU/RAM collector"
  python3 "${ROOT_DIR}/scripts/collect-resources.py" \
    --output "${RESOURCE_FILE}" \
    --interval "${RESOURCE_SAMPLE_SECONDS}" &
  RESOURCE_PID=$!
fi

# Keep the structured summary out of the interactive console output.
# The full JSON remains available in Kubernetes pod logs as a recovery channel.
msg "Streaming k6 logs"
(
  kubectl logs -n "${APP_NS}" -f "${POD_NAME}" -c k6 --pod-running-timeout=180s 2>&1 |
  while IFS= read -r line; do
    case "${line}" in
      __DIPLOMA_K6_JSON_*) ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done
) &
LOGS_PID=$!

# Start k6 after metadata and the CPU/RAM collector are ready.
kubectl exec -n "${APP_NS}" "${POD_NAME}" -c k6 -- \
  sh -c "touch /results/.start"

if ! wait_for_pod_file "${APP_NS}" "${POD_NAME}" /results/.k6-finished 1200; then
  warn "Timed out waiting for the k6 completion marker; attempting log recovery"
fi

# First try to copy the file directly. On some Docker Desktop / k3d setups,
# kubectl exec can fail near container completion, leaving valid k6 results in
# pod logs but no local JSON. Never acknowledge collection before recovery.
SUMMARY_OK=false
for attempt in 1 2 3 4 5; do
  candidate="${SUMMARY_FILE}.partial"
  rm -f "${candidate}"
  if copy_pod_file "${APP_NS}" "${POD_NAME}" /results/summary.json "${candidate}" &&
     python3 "${ROOT_DIR}/scripts/recover-k6-summary.py" --validate "${candidate}" >/dev/null 2>&1; then
    mv -f "${candidate}" "${SUMMARY_FILE}"
    SUMMARY_OK=true
    break
  fi
  sleep 1
done
rm -f "${SUMMARY_FILE}.partial"

# k6 handleSummary emits a second JSON representation into its log stream.
# This works even if the container already terminated or file transfer failed.
if [[ "${SUMMARY_OK}" != "true" ]]; then
  warn "Direct JSON collection failed; recovering summary from k6 logs"
  for attempt in 1 2 3; do
    if kubectl logs -n "${APP_NS}" "${POD_NAME}" -c k6 > "${RUN_TMP_DIR}/k6.log" 2>"${RUN_TMP_DIR}/kubectl-logs.err" &&
       python3 "${ROOT_DIR}/scripts/recover-k6-summary.py" \
         --logs "${RUN_TMP_DIR}/k6.log" --output "${SUMMARY_FILE}"; then
      SUMMARY_OK=true
      msg "Recovered summary JSON from k6 logs"
      break
    fi
    sleep 2
  done
fi

# Let the job terminate after successful retrieval or a recorded failure.
if ! kubectl exec -n "${APP_NS}" "${POD_NAME}" -c k6 -- \
    sh -c "touch /results/.copied" >/dev/null 2>&1; then
  warn "Could not signal k6 job completion (pod may already be terminated)"
fi

if [[ -n "${RESOURCE_PID}" ]]; then
  kill "${RESOURCE_PID}" >/dev/null 2>&1 || true
  wait "${RESOURCE_PID}" 2>/dev/null || true
  RESOURCE_PID=""
fi

# Avoid waiting for the full pod hold timeout if the completion signal failed.
kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${APP_NS}" --timeout=30s >/dev/null 2>&1 \
  || kubectl wait --for=condition=failed "job/${JOB_NAME}" -n "${APP_NS}" --timeout=10s >/dev/null 2>&1 \
  || true
# The log follower may remain attached if Kubernetes cannot terminate the pod.
# Do not let it block the next run for the container's 600-second hold timeout.
if [[ -n "${LOGS_PID}" ]]; then
  kill "${LOGS_PID}" >/dev/null 2>&1 || true
  wait "${LOGS_PID}" 2>/dev/null || true
fi
LOGS_PID=""

if [[ "${SUMMARY_OK}" != "true" || ! -s "${SUMMARY_FILE}" ]]; then
  FAIL_DIR="${RESULTS_DIR}/failed-runs/${RUN_ID}"
  mkdir -p "${FAIL_DIR}"
  cp -f "${METADATA_FILE}" "${FAIL_DIR}/metadata.json" 2>/dev/null || true
  kubectl logs -n "${APP_NS}" "${POD_NAME}" -c k6 > "${FAIL_DIR}/k6.log" 2>&1 || true
  kubectl describe pod "${POD_NAME}" -n "${APP_NS}" > "${FAIL_DIR}/pod-description.txt" 2>&1 || true
  warn "Failed run diagnostics saved: ${FAIL_DIR}"
  die "Summary file was not collected. See diagnostics in ${FAIL_DIR}"
fi

python3 "${ROOT_DIR}/scripts/summary-to-csv.py" \
  "${SUMMARY_FILE}" \
  "${RESULTS_DIR}/benchmark-summary.csv" \
  --run-id "${RUN_ID}" \
  --metadata "${METADATA_FILE}"

if [[ "${RESOURCE_CSV_ENABLED}" == "true" && -f "${RESOURCE_FILE}" ]]; then
  python3 "${ROOT_DIR}/scripts/summarize-resources.py" \
    "${RESOURCE_FILE}" \
    --master "${RESULTS_DIR}/benchmark-resources.csv" \
    --run-id "${RUN_ID}" \
    --model "${MODEL}" \
    --profile "${PROFILE}" \
    --scenario-variant "${SCENARIO_VARIANT}" \
    --rps "${RPS}" \
    --no-connection-reuse "${NO_CONNECTION_REUSE}" \
    --config-id "${CONFIG_ID}"
fi

echo
python3 "${ROOT_DIR}/scripts/pretty-summary.py" "${SUMMARY_FILE}"
echo
msg "Saved CSV rows to:"
echo "  ${RESULTS_DIR}/benchmark-summary.csv"
echo "  ${RESULTS_DIR}/benchmark-configs/${CONFIG_ID}.json"
if [[ "${RESOURCE_CSV_ENABLED}" == "true" ]]; then
  echo "  ${RESULTS_DIR}/benchmark-resources.csv"
fi
