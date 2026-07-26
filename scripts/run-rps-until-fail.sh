#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> [steady-rps.js]"
  exit 1
fi

MODEL="$1"
K6_SCRIPT="${2:-steady-rps.js}"
MODEL_SHORT="$(model_short "${MODEL}")"

check_jq

START_RPS="${START_RPS:-50}"
STEP_RPS="${STEP_RPS:-50}"
DURATION="${DURATION:-1m}"
BENCHMARK_VUS="${BENCHMARK_VUS:-200}"
MAX_RUNS="${MAX_RUNS:-30}"
EXTRA_RUNS_AFTER_FAIL="${EXTRA_RUNS_AFTER_FAIL:-2}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
FAIL_RATE_LIMIT="${FAIL_RATE_LIMIT:-0.01}"
SUCCESS_RATE_LIMIT="${SUCCESS_RATE_LIMIT:-0.99}"
P95_LIMIT_MS="${P95_LIMIT_MS:-500}"
MIN_ACHIEVED_RATIO="${MIN_ACHIEVED_RATIO:-0.99}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"

rps="${START_RPS}"
run_id=1
failure_seen=0
after_failure_runs_done=0
first_bad_rps=""

while (( run_id <= MAX_RUNS )); do
  echo
  msg "Run #${run_id}: target RPS=${rps}, duration=${DURATION}"

  if ! env \
    MODEL="${MODEL}" \
    RUN_TAG="rps-until-fail-${run_id}" \
    VUS="${BENCHMARK_VUS}" \
    RPS="${rps}" \
    DURATION="${DURATION}" \
    TARGET_URL="${TARGET_URL}" \
    TEST_MODE=allowed \
    SLEEP_MS=0 \
    FAIL_RATE_THRESHOLD="${FAIL_RATE_LIMIT}" \
    SUCCESS_RATE_THRESHOLD="${SUCCESS_RATE_LIMIT}" \
    P95_THRESHOLD_MS="${P95_LIMIT_MS}" \
    bash "${ROOT_DIR}/scripts/run-k6.sh" "${MODEL}" "${K6_SCRIPT}"; then
    warn "k6 reported a failed threshold for target RPS=${rps}"
  fi

  LAST_SUMMARY_FILE="${TMP_DIR}/last-summary-${MODEL_SHORT}.txt"
  [[ -f "${LAST_SUMMARY_FILE}" ]] || die "Last summary pointer not found: ${LAST_SUMMARY_FILE}"
  SUMMARY_FILE="$(cat "${LAST_SUMMARY_FILE}")"
  [[ -f "${SUMMARY_FILE}" ]] || die "Summary file not found: ${SUMMARY_FILE}"

  fail_rate="$(jq -r '.metrics.http_req_failed.values.rate // 0' "${SUMMARY_FILE}")"
  success_rate="$(jq -r '.metrics.expected_status_rate.values.rate // .metrics.success_rate.values.rate // 1' "${SUMMARY_FILE}")"
  http_p95="$(jq -r '.metrics.http_req_duration.values["p(95)"] // 0' "${SUMMARY_FILE}")"
  achieved_rps="$(jq -r '.metrics.http_reqs.values.rate // 0' "${SUMMARY_FILE}")"
  dropped="$(jq -r '.metrics.dropped_iterations.values.count // 0' "${SUMMARY_FILE}")"

  min_achieved="$(awk -v target="${rps}" -v ratio="${MIN_ACHIEVED_RATIO}" 'BEGIN { print target * ratio }')"

  current_run_is_bad="$(awk \
    -v f="${fail_rate}" \
    -v s="${success_rate}" \
    -v p="${http_p95}" \
    -v d="${dropped}" \
    -v a="${achieved_rps}" \
    -v min_a="${min_achieved}" \
    -v max_f="${FAIL_RATE_LIMIT}" \
    -v min_s="${SUCCESS_RATE_LIMIT}" \
    -v max_p="${P95_LIMIT_MS}" \
    'BEGIN {
      if (f > max_f || s < min_s || p > max_p || d > 0 || a < min_a) print 1;
      else print 0;
    }')"

  echo "  fail_rate=${fail_rate}"
  echo "  expected_status_rate=${success_rate}"
  echo "  p95_ms=${http_p95}"
  echo "  achieved_rps=${achieved_rps}"
  echo "  dropped_iterations=${dropped}"

  first_failure_this_run=0
  if [[ "${current_run_is_bad}" == "1" && "${failure_seen}" == "0" ]]; then
    failure_seen=1
    first_failure_this_run=1
    first_bad_rps="${rps}"
    warn "First SLO degradation detected at target RPS=${rps}"
  fi

  if [[ "${failure_seen}" == "1" && "${first_failure_this_run}" == "0" ]]; then
    after_failure_runs_done=$((after_failure_runs_done + 1))
    if (( after_failure_runs_done >= EXTRA_RUNS_AFTER_FAIL )); then
      break
    fi
  fi

  rps=$((rps + STEP_RPS))
  run_id=$((run_id + 1))

  if (( COOLDOWN_SECONDS > 0 )); then
    sleep "${COOLDOWN_SECONDS}"
  fi
done

echo
if [[ -n "${first_bad_rps}" ]]; then
  msg "First detected degradation at target RPS=${first_bad_rps}"
  msg "Last sustainable tested point is approximately RPS=$((first_bad_rps - STEP_RPS))"
else
  warn "No degradation detected within MAX_RUNS=${MAX_RUNS}"
fi
