#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  run-benchmark-suite.sh <model|all> <verify|steady|churn|all>

Examples:
  bash scripts/run-benchmark-suite.sh calico-l4 verify
  RATES="100 200 300 400 500" REPEATS=3 bash scripts/run-benchmark-suite.sh ambient-l7 steady
  CHURN_RPS=200 REPEATS=3 bash scripts/run-benchmark-suite.sh calico-l7 churn
USAGE
}

[[ $# -eq 2 ]] || { usage; exit 1; }

MODEL_SELECTOR="$1"
SUITE="$2"

if [[ "${MODEL_SELECTOR}" == "all" ]]; then
  mapfile -t MODELS < <(all_models)
else
  MODELS=("$(canonical_model "${MODEL_SELECTOR}")")
fi

case "${SUITE}" in
  verify|policy|steady|churn|all) ;;
  *) usage; exit 1 ;;
esac

RATES="${RATES:-100 200 300 400 500}"
REPEATS="${REPEATS:-3}"
BENCHMARK_VUS="${BENCHMARK_VUS:-300}"
STEADY_DURATION="${STEADY_DURATION:-45s}"
VERIFY_DURATION="${VERIFY_DURATION:-5s}"
CHURN_RPS="${CHURN_RPS:-200}"
CHURN_DURATION="${CHURN_DURATION:-45s}"
CHURN_COMPARE_REUSE="${CHURN_COMPARE_REUSE:-true}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
SERVER_RECOVERY_WAIT_SECONDS="${SERVER_RECOVERY_WAIT_SECONDS:-30}"

server_local_responds() {
  kubectl exec -n "${APP_NS}" deployment/server -c server -- \
    wget -q -T 3 -O - http://127.0.0.1:8080/health >/dev/null 2>&1
}

server_service_responds() {
  kubectl exec -n "${APP_NS}" deployment/client -c client -- \
    wget -q -T 3 -O - http://server:8080/health >/dev/null 2>&1
}

wait_for_server_path() {
  local end_ts=$((SECONDS + SERVER_RECOVERY_WAIT_SECONDS))
  while (( SECONDS < end_ts )); do
    if server_local_responds && server_service_responds; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_model_ready() {
  local model="$1"
  local cluster_name
  cluster_name="$(model_cluster "${model}")"
  cluster_exists "${cluster_name}" || die "Cluster ${cluster_name} does not exist. Run scripts/up.sh ${model} first"
  use_cluster "${cluster_name}"
  if ! wait_for_server_path; then
    kubectl get pods -n "${APP_NS}" -o wide || true
    kubectl get svc,endpoints -n "${APP_NS}" || true
    die "${model} is not healthy enough to benchmark"
  fi
}

cooldown() {
  if (( COOLDOWN_SECONDS > 0 )); then
    sleep "${COOLDOWN_SECONDS}"
  fi
}

run_case() {
  local model="$1"
  local script="$2"
  shift 2

  ensure_model_ready "${model}"
  if ! env "$@" bash "${ROOT_DIR}/scripts/run-k6.sh" "${model}" "${script}"; then
    warn "k6 returned a non-zero status for ${model}/${script}; collected results remain useful for analysis"
  fi
  cooldown
}

run_verify_suite() {
  local model="$1"

  msg "Verification: ${model} allowed GET"
  run_case "${model}" policy-verify.js \
    RUN_TAG=verify-allowed \
    VUS=1 DURATION="${VERIFY_DURATION}" RPS=0 \
    TARGET_URL=http://server:8080 REQUEST_METHOD=GET REQUEST_PATH=/api/data \
    TEST_MODE=allowed TIMEOUT=3s NO_CONNECTION_REUSE=false

  case "${model}" in
    calico-baseline|ambient-baseline)
      msg "Verification: ${model} baseline has no L4 block"
      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-baseline-open-8081 \
        VUS=1 DURATION="${VERIFY_DURATION}" RPS=0 \
        TARGET_URL=http://server:8081 REQUEST_METHOD=GET REQUEST_PATH=/health \
        TEST_MODE=baseline-open TIMEOUT=3s NO_CONNECTION_REUSE=false
      ;;
    calico-l4|ambient-l4)
      msg "Verification: ${model} blocks port 8081"
      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-l4-blocked \
        VUS=1 DURATION="${VERIFY_DURATION}" RPS=0 \
        TARGET_URL=http://server:8081 REQUEST_METHOD=GET REQUEST_PATH=/health \
        TEST_MODE=l4-blocked TIMEOUT=2s NO_CONNECTION_REUSE=true
      ;;
    calico-l7|ambient-l7)
      msg "Verification: ${model} blocks POST /api/data at L7"
      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-l7-blocked \
        VUS=1 DURATION="${VERIFY_DURATION}" RPS=0 \
        TARGET_URL=http://server:8080 REQUEST_METHOD=POST REQUEST_PATH=/api/data \
        TEST_MODE=l7-blocked TIMEOUT=3s NO_CONNECTION_REUSE=false
      ;;
  esac
}

run_steady_suite() {
  local model="$1"
  local rate run

  for rate in ${RATES}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Steady ${model}: RPS=${rate}, repetition=${run}/${REPEATS}"
      run_case "${model}" steady-rps.js \
        RUN_TAG="steady-rps${rate}-run${run}" \
        VUS="${BENCHMARK_VUS}" \
        RPS="${rate}" \
        DURATION="${STEADY_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        TEST_MODE=allowed \
        NO_CONNECTION_REUSE=false \
        SLEEP_MS=0
    done
  done
}

run_churn_suite() {
  local model="$1"
  local run reuse_values

  if [[ "${CHURN_COMPARE_REUSE}" == "true" ]]; then
    reuse_values="false true"
  else
    reuse_values="true"
  fi

  for reuse in ${reuse_values}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Connection ${model}: noConnectionReuse=${reuse}, repetition=${run}/${REPEATS}"
      run_case "${model}" connection-churn.js \
        RUN_TAG="churn-${reuse}-run${run}" \
        VUS="${BENCHMARK_VUS}" \
        RPS="${CHURN_RPS}" \
        DURATION="${CHURN_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        TEST_MODE=allowed \
        NO_CONNECTION_REUSE="${reuse}" \
        SLEEP_MS=0
    done
  done
}

for model in "${MODELS[@]}"; do
  case "${SUITE}" in
    verify|policy)
      run_verify_suite "${model}"
      ;;
    steady)
      run_steady_suite "${model}"
      ;;
    churn)
      run_churn_suite "${model}"
      ;;
    all)
      run_verify_suite "${model}"
      run_steady_suite "${model}"
      run_churn_suite "${model}"
      ;;
  esac
done

msg "Benchmark suite finished"
