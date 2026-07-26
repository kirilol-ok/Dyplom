#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  run-benchmark-suite.sh <baseline|ambient-l4|l7-dikastes|all> \
    <policy|steady|saturation|churn|concurrency|all>

Examples:
  bash scripts/run-benchmark-suite.sh baseline policy
  RATES="205 210 215" REPEATS=3 bash scripts/run-benchmark-suite.sh baseline steady
  SATURATION_MAX_RPS=1000 bash scripts/run-benchmark-suite.sh ambient-l4 saturation
USAGE
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

APP_NS="${APP_NS:-test-app}"

SERVER_CHECK_URL="${SERVER_CHECK_URL:-http://server:8080/api/data?response_size=16&server_delay_ms=0}"
SERVER_RECOVERY_WAIT_SECONDS="${SERVER_RECOVERY_WAIT_SECONDS:-60}"
SERVER_RESTART_TIMEOUT="${SERVER_RESTART_TIMEOUT:-180s}"

MODEL_SELECTOR="$1"
SUITE="$2"

BENCHMARK_TARGET_MODE="${TARGET_MODE:-direct}"
case "${BENCHMARK_TARGET_MODE}" in
  direct)
    BENCHMARK_TARGET_URL="${TARGET_URL:-http://server:8080}"
    ;;
  proxy)
    BENCHMARK_TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
    ;;
  *)
    die "Unknown TARGET_MODE=${BENCHMARK_TARGET_MODE}. Use direct or proxy"
    ;;
esac

POLICY_TARGET_MODE="${POLICY_TARGET_MODE:-proxy}"
POLICY_TARGET_URL="${POLICY_TARGET_URL:-http://client:8080/proxy}"

COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
REPEATS="${REPEATS:-3}"
RATES="${RATES:-50 100 200 400}"
BENCHMARK_VUS="${BENCHMARK_VUS:-200}"
STEADY_DURATION="${STEADY_DURATION:-2m}"
POLICY_DURATION="${POLICY_DURATION:-15s}"
SATURATION_STAGE_DURATION="${SATURATION_STAGE_DURATION:-30s}"
SATURATION_MAX_RPS="${SATURATION_MAX_RPS:-1000}"
CHURN_RPS="${CHURN_RPS:-200}"
CHURN_DURATION="${CHURN_DURATION:-2m}"
CONCURRENCY_VUS_LIST="${CONCURRENCY_VUS_LIST:-20 50 100 200}"
CONCURRENCY_DURATION="${CONCURRENCY_DURATION:-1m}"

case "${MODEL_SELECTOR}" in
  baseline|ambient-l4|l7-dikastes)
    MODELS=("${MODEL_SELECTOR}")
    ;;
  all)
    MODELS=(baseline ambient-l4 l7-dikastes)
    ;;
  *)
    usage
    exit 1
    ;;
esac

case "${SUITE}" in
  policy|steady|saturation|churn|concurrency|all)
    ;;
  *)
    usage
    exit 1
    ;;
esac

server_responds() {
  kubectl exec -i \
    -n "${APP_NS}" \
    deployment/client \
    -c client \
    -- python - "${SERVER_CHECK_URL}" <<'PY'
import sys
import urllib.request

url = sys.argv[1]

try:
    with urllib.request.urlopen(url, timeout=3) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
}

wait_for_server() {
  local timeout_seconds="${1:-60}"
  local end_time=$((SECONDS + timeout_seconds))

  while (( SECONDS < end_time )); do
    if server_responds >/dev/null 2>&1; then
      return 0
    fi

    sleep 5
  done

  return 1
}

recover_server_if_needed() {
  local model="$1"
  local cluster_name

  cluster_name="$(model_cluster "${model}")"
  use_cluster "${cluster_name}"

  msg "Checking whether server recovered after the test"

  if wait_for_server "${SERVER_RECOVERY_WAIT_SECONDS}"; then
    msg "Server is healthy, restart is not required"
    return 0
  fi

  warn "Server is still unreachable, restarting deployment/server once"

  kubectl rollout restart \
    deployment/server \
    -n "${APP_NS}"

  if ! kubectl rollout status \
    deployment/server \
    -n "${APP_NS}" \
    --timeout="${SERVER_RESTART_TIMEOUT}"; then

    warn "Server rollout did not finish"

    kubectl get pods \
      -n "${APP_NS}" \
      -l app=server \
      -o wide || true

    return 1
  fi

  msg "Waiting for server HTTP endpoint after restart"

  if ! wait_for_server "${SERVER_RECOVERY_WAIT_SECONDS}"; then
    warn "Server is unavailable after restart"

    kubectl get pods \
      -n "${APP_NS}" \
      -l app=server \
      -o wide || true

    kubectl logs \
      -n "${APP_NS}" \
      deployment/server \
      -c server \
      --tail=100 || true

    return 1
  fi

  msg "Server recovered successfully"
}

run_k6_case() {
  local model="$1"
  local script="$2"
  shift 2

  msg "Running ${script} for ${model}"

  if ! env \
    "$@" \
    bash "${ROOT_DIR}/scripts/run-k6.sh" "${model}" "${script}"; then
    warn "The k6 run returned a non-zero status. Results should still be available if summary.json was created."
  fi

  if (( COOLDOWN_SECONDS > 0 )); then
    msg "Cooldown for ${COOLDOWN_SECONDS}s"
    sleep "${COOLDOWN_SECONDS}"
  fi

  recover_server_if_needed "${model}" \
    || die "Server could not be recovered after the benchmark"
}

run_policy_suite() {
  local model="$1"
  local mode

  for mode in allowed blocked admin-blocked mixed; do
    run_k6_case "${model}" policy-test.js \
      TARGET_MODE="${POLICY_TARGET_MODE}" \
      TARGET_URL="${POLICY_TARGET_URL}" \
      MODEL="${model}" \
      VUS=1 \
      DURATION="${POLICY_DURATION}" \
      TEST_MODE="${mode}" \
      SLEEP_MS=100 \
      FAIL_RATE_THRESHOLD=0.001 \
      SUCCESS_RATE_THRESHOLD=1 \
      P95_THRESHOLD_MS=1000
  done
}

run_steady_suite() {
  local model="$1"
  local rate run

  for rate in ${RATES}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Steady test ${model}: rate=${rate}, repetition=${run}/${REPEATS}"

      run_k6_case "${model}" steady-rps.js \
        TARGET_MODE="${BENCHMARK_TARGET_MODE}" \
        TARGET_URL="${BENCHMARK_TARGET_URL}" \
        MODEL="${model}" \
        RUN_TAG="steady-rps${rate}-run${run}" \
        VUS="${BENCHMARK_VUS}" \
        RPS="${rate}" \
        DURATION="${STEADY_DURATION}" \
        TEST_MODE=allowed \
        SLEEP_MS=0
    done
  done
}

run_saturation_suite() {
  local model="$1"

  run_k6_case "${model}" saturation.js \
    TARGET_MODE="${BENCHMARK_TARGET_MODE}" \
    TARGET_URL="${BENCHMARK_TARGET_URL}" \
    MODEL="${model}" \
    RUN_TAG="saturation-max${SATURATION_MAX_RPS}" \
    VUS="${BENCHMARK_VUS}" \
    RPS="${SATURATION_MAX_RPS}" \
    DURATION="${SATURATION_STAGE_DURATION}" \
    TEST_MODE=allowed \
    SLEEP_MS=0
}

run_churn_suite() {
  local model="$1"
  local reuse run

  for reuse in false true; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Connection test ${model}: noConnectionReuse=${reuse}, repetition=${run}/${REPEATS}"
      run_k6_case "${model}" connection-churn.js \
        TARGET_MODE="${BENCHMARK_TARGET_MODE}" \
        TARGET_URL="${BENCHMARK_TARGET_URL}" \
        MODEL="${model}" \
        RUN_TAG="churn-${reuse}-run${run}" \
        VUS="${BENCHMARK_VUS}" \
        RPS="${CHURN_RPS}" \
        DURATION="${CHURN_DURATION}" \
        TEST_MODE=allowed \
        NO_CONNECTION_REUSE="${reuse}" \
        SLEEP_MS=0
    done
  done
}

run_concurrency_suite() {
  local model="$1"
  local vus run

  for vus in ${CONCURRENCY_VUS_LIST}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Concurrency test ${model}: VUS=${vus}, repetition=${run}/${REPEATS}"
      run_k6_case "${model}" concurrency-vus.js \
        TARGET_MODE="${BENCHMARK_TARGET_MODE}" \
        TARGET_URL="${BENCHMARK_TARGET_URL}" \
        MODEL="${model}" \
        RUN_TAG="concurrency-vus${vus}-run${run}" \
        VUS="${vus}" \
        DURATION="${CONCURRENCY_DURATION}" \
        TEST_MODE=allowed \
        SLEEP_MS=100
    done
  done
}

for model in "${MODELS[@]}"; do
  case "${SUITE}" in
    policy)
      run_policy_suite "${model}"
      ;;
    steady)
      run_steady_suite "${model}"
      ;;
    saturation)
      run_saturation_suite "${model}"
      ;;
    churn)
      run_churn_suite "${model}"
      ;;
    concurrency)
      run_concurrency_suite "${model}"
      ;;
    all)
      run_policy_suite "${model}"
      run_steady_suite "${model}"
      run_saturation_suite "${model}"
      run_churn_suite "${model}"
      run_concurrency_suite "${model}"
      ;;
  esac
done

msg "Benchmark suite finished"
