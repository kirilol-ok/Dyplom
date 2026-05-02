#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> [script.js]"
  exit 1
fi

MODEL="$1"
K6_SCRIPT="${2:-loadtest.js}"
MODEL_SHORT="$(model_short "${MODEL}")"

check_jq

START_VUS="${START_VUS:-20}"
STEP_VUS="${STEP_VUS:-10}"
DURATION="${DURATION:-30s}"
EXTRA_RUNS_AFTER_FAIL="${EXTRA_RUNS_AFTER_FAIL:-5}"
MAX_RUNS="${MAX_RUNS:-100}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
TEST_MODE="${TEST_MODE:-allowed}"
FAIL_CONDITION="${FAIL_CONDITION:-any_error}"

vus="${START_VUS}"
run_id=1
failure_seen=0
after_failure_runs_done=0
first_bad_vus=""

while (( run_id <= MAX_RUNS )); do
  echo
  msg "Run #${run_id}"
  msg "Testing with VUS=${vus}, DURATION=${DURATION}, TARGET_URL=${TARGET_URL}, MODE=${TEST_MODE}"

  RUN_TAG="$(date +%Y%m%d-%H%M%S)-run${run_id}" \
  VUS="${vus}" DURATION="${DURATION}" TARGET_URL="${TARGET_URL}" TEST_MODE="${TEST_MODE}" \
    bash "${ROOT_DIR}/scripts/run-k6.sh" "${MODEL}" "${K6_SCRIPT}"

  LAST_SUMMARY_FILE="${TMP_DIR}/last-summary-${MODEL_SHORT}.txt"
  [[ -f "${LAST_SUMMARY_FILE}" ]] || die "Last summary pointer not found: ${LAST_SUMMARY_FILE}"
  SUMMARY_FILE="$(cat "${LAST_SUMMARY_FILE}")"
  [[ -f "${SUMMARY_FILE}" ]] || die "Summary file not found after run: ${SUMMARY_FILE}"

  fail_rate="$(jq -r '.metrics.http_req_failed.values.rate // 0' "${SUMMARY_FILE}")"
  success_rate="$(jq -r '.metrics.success_rate.values.rate // 1' "${SUMMARY_FILE}")"
  http_avg="$(jq -r '.metrics.http_req_duration.values.avg // 0' "${SUMMARY_FILE}")"
  http_p95="$(jq -r '.metrics.http_req_duration.values["p(95)"] // 0' "${SUMMARY_FILE}")"
  req_rate="$(jq -r '.metrics.http_reqs.values.rate // 0' "${SUMMARY_FILE}")"

  msg "Parsed summary:"
  echo "  fail_rate=${fail_rate}"
  echo "  success_rate=${success_rate}"
  echo "  http_avg_ms=${http_avg}"
  echo "  http_p95_ms=${http_p95}"
  echo "  req_per_sec=${req_rate}"

  case "${FAIL_CONDITION}" in
    any_error)
      current_run_is_bad="$(awk -v f="${fail_rate}" -v s="${success_rate}" 'BEGIN { if (f > 0 || s < 1) print 1; else print 0; }')"
      ;;
    threshold)
      current_run_is_bad="$(awk -v f="${fail_rate}" -v s="${success_rate}" -v p="${http_p95}" 'BEGIN { if (f > 0.05 || s < 0.95 || p > 1000) print 1; else print 0; }')"
      ;;
    *)
      die "Unknown FAIL_CONDITION=${FAIL_CONDITION}. Use any_error or threshold"
      ;;
  esac

  first_failure_this_run=0

  if [[ "${current_run_is_bad}" == "1" && "${failure_seen}" == "0" ]]; then
    failure_seen=1
    first_failure_this_run=1
    first_bad_vus="${vus}"
    warn "First degradation detected at VUS=${vus}"
    warn "Will continue for ${EXTRA_RUNS_AFTER_FAIL} additional runs"
  fi

  if [[ "${failure_seen}" == "1" && "${first_failure_this_run}" == "0" ]]; then
    after_failure_runs_done=$((after_failure_runs_done + 1))
    msg "Post-degradation follow-up run: ${after_failure_runs_done}/${EXTRA_RUNS_AFTER_FAIL}"

    if (( after_failure_runs_done >= EXTRA_RUNS_AFTER_FAIL )); then
      msg "Stop condition reached"
      break
    fi
  fi

  vus=$((vus + STEP_VUS))
  run_id=$((run_id + 1))
done

echo
msg "Finished"
if [[ -n "${first_bad_vus}" ]]; then
  msg "First detected degradation at VUS=${first_bad_vus}"
else
  warn "No degradation detected within MAX_RUNS=${MAX_RUNS}"
fi
