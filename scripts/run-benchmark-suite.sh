#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  run-benchmark-suite.sh <model|all> <verify|steady|churn|concurrency|saturation|l4-attack|l7-spaghetti|all>

Examples:
  bash scripts/run-benchmark-suite.sh calico-l4 verify

  RATES="100 200 300 400 500" \
  REPEATS=3 \
  bash scripts/run-benchmark-suite.sh ambient-l7 steady

  CHURN_RATES="100 200 300 400 500" \
  BENCHMARK_VUS=400 \
  REPEATS=3 \
  bash scripts/run-benchmark-suite.sh calico-l7 churn

  VUS_LEVELS="5 10 20 40 80 120 160" \
  REPEATS=3 \
  CONCURRENCY_DURATION=45s \
  bash scripts/run-benchmark-suite.sh calico-baseline concurrency

  SATURATION_RATES="1000 1250 1500 1750 2000 2250" \
  SATURATION_VUS=1000 \
  REPEATS=1 \
  SATURATION_DURATION=30s \
  bash scripts/run-benchmark-suite.sh calico-baseline saturation

  L4_ATTACK_RATES="200 400 600" \
  L4_ATTACK_BLOCKED_PERCENT=50 \
  bash scripts/run-benchmark-suite.sh calico-l4 l4-attack

  L7_SPAGHETTI_RPS=300 \
  L7_SPAGHETTI_VARIANTS="simple spaghetti" \
  bash scripts/run-benchmark-suite.sh ambient-l7 l7-spaghetti
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
  verify|policy|steady|churn|concurrency|saturation|l4-attack|l7-spaghetti|all) ;;
  *) usage; exit 1 ;;
esac

RATES="${RATES:-100 200 300 400 500}"
REPEATS="${REPEATS:-3}"
BENCHMARK_VUS="${BENCHMARK_VUS:-300}"
STEADY_DURATION="${STEADY_DURATION:-45s}"
VERIFY_DURATION="${VERIFY_DURATION:-5s}"

# CHURN_RATES accepts a space-separated list, e.g. "100 200 300 400 500".
# CHURN_RPS is kept as a backwards-compatible fallback for old commands.
CHURN_RATES="${CHURN_RATES:-${CHURN_RPS:-200}}"
CHURN_DURATION="${CHURN_DURATION:-45s}"
CHURN_COMPARE_REUSE="${CHURN_COMPARE_REUSE:-true}"
# Give a freshly created cluster time to finish background reconciliation before
# the first measured churn run. Set to 0 to disable.
CHURN_INITIAL_SETTLE_SECONDS="${CHURN_INITIAL_SETTLE_SECONDS:-60}"

VUS_LEVELS="${VUS_LEVELS:-5 10 20 40 80}"
CONCURRENCY_DURATION="${CONCURRENCY_DURATION:-45s}"
CONCURRENCY_SLEEP_MS="${CONCURRENCY_SLEEP_MS:-100}"

SATURATION_RATES="${SATURATION_RATES:-1000 1250 1500 1750 2000 2250}"
SATURATION_VUS="${SATURATION_VUS:-1000}"
SATURATION_DURATION="${SATURATION_DURATION:-30s}"

L4_ATTACK_RATES="${L4_ATTACK_RATES:-200 400 600}"
L4_ATTACK_BLOCKED_PERCENT="${L4_ATTACK_BLOCKED_PERCENT:-50}"
L4_ATTACK_DURATION="${L4_ATTACK_DURATION:-45s}"
L4_ATTACK_VUS="${L4_ATTACK_VUS:-300}"
L4_ATTACK_TIMEOUT="${L4_ATTACK_TIMEOUT:-1s}"

L7_SPAGHETTI_RPS="${L7_SPAGHETTI_RPS:-300}"
L7_SPAGHETTI_BLOCKED_PERCENT="${L7_SPAGHETTI_BLOCKED_PERCENT:-50}"
L7_SPAGHETTI_DURATION="${L7_SPAGHETTI_DURATION:-45s}"
L7_SPAGHETTI_VUS="${L7_SPAGHETTI_VUS:-300}"
L7_SPAGHETTI_VARIANTS="${L7_SPAGHETTI_VARIANTS:-simple spaghetti}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-5}"

COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
SERVER_RECOVERY_WAIT_SECONDS="${SERVER_RECOVERY_WAIT_SECONDS:-30}"
ACTIVE_L7_POLICY_MODEL=""

restore_active_l7_policy() {
  if [[ -n "${ACTIVE_L7_POLICY_MODEL}" ]]; then
    use_cluster "$(model_cluster "${ACTIVE_L7_POLICY_MODEL}")" >/dev/null 2>&1 || true
    restore_simple_l7_policy "${ACTIVE_L7_POLICY_MODEL}" >/dev/null 2>&1 || true
    ACTIVE_L7_POLICY_MODEL=""
  fi
}

trap restore_active_l7_policy EXIT

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

  cluster_exists "${cluster_name}" || \
    die "Cluster ${cluster_name} does not exist. Run scripts/up.sh ${model} first"

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
    VUS=1 \
    DURATION="${VERIFY_DURATION}" \
    RPS=0 \
    TARGET_URL=http://server:8080 \
    REQUEST_METHOD=GET \
    REQUEST_PATH=/api/data \
    TEST_MODE=allowed \
    TIMEOUT=3s \
    NO_CONNECTION_REUSE=false

  case "${model}" in
    calico-baseline|ambient-baseline)
      msg "Verification: ${model} baseline has no L4 block"

      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-baseline-open-8081 \
        VUS=1 \
        DURATION="${VERIFY_DURATION}" \
        RPS=0 \
        TARGET_URL=http://server:8081 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/health \
        TEST_MODE=baseline-open \
        TIMEOUT=3s \
        NO_CONNECTION_REUSE=false
      ;;

    calico-l4|ambient-l4)
      msg "Verification: ${model} blocks port 8081"

      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-l4-blocked \
        VUS=1 \
        DURATION="${VERIFY_DURATION}" \
        RPS=0 \
        TARGET_URL=http://server:8081 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/health \
        TEST_MODE=l4-blocked \
        TIMEOUT=2s \
        NO_CONNECTION_REUSE=true
      ;;

    calico-l7|ambient-l7)
      msg "Verification: ${model} blocks POST /api/data at L7"

      run_case "${model}" policy-verify.js \
        RUN_TAG=verify-l7-blocked \
        VUS=1 \
        DURATION="${VERIFY_DURATION}" \
        RPS=0 \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=POST \
        REQUEST_PATH=/api/data \
        TEST_MODE=l7-blocked \
        TIMEOUT=3s \
        NO_CONNECTION_REUSE=false
      ;;
  esac
}

run_steady_suite() {
  local model="$1"
  local rate
  local run

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
  local rate
  local run
  local reuse
  local reuse_values

  ensure_model_ready "${model}"
  if (( CHURN_INITIAL_SETTLE_SECONDS > 0 )); then
    msg "Settling ${model} for ${CHURN_INITIAL_SETTLE_SECONDS}s before churn measurements"
    sleep "${CHURN_INITIAL_SETTLE_SECONDS}"
  fi

  if [[ "${CHURN_COMPARE_REUSE}" == "true" ]]; then
    reuse_values="false true"
  else
    reuse_values="true"
  fi

  for rate in ${CHURN_RATES}; do
    for reuse in ${reuse_values}; do
      for run in $(seq 1 "${REPEATS}"); do
        msg "Connection ${model}: RPS=${rate}, noConnectionReuse=${reuse}, repetition=${run}/${REPEATS}"

        run_case "${model}" connection-churn.js \
          RUN_TAG="churn-rps${rate}-${reuse}-run${run}" \
          VUS="${BENCHMARK_VUS}" \
          RPS="${rate}" \
          DURATION="${CHURN_DURATION}" \
          TARGET_URL=http://server:8080 \
          REQUEST_METHOD=GET \
          REQUEST_PATH=/api/data \
          TEST_MODE=allowed \
          NO_CONNECTION_REUSE="${reuse}" \
          SLEEP_MS=0
      done
    done
  done
}

run_concurrency_suite() {
  local model="$1"
  local vus
  local run

  for vus in ${VUS_LEVELS}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Concurrency ${model}: VUS=${vus}, repetition=${run}/${REPEATS}"

      run_case "${model}" concurrency-vus.js \
        RUN_TAG="concurrency-vus${vus}-run${run}" \
        VUS="${vus}" \
        RPS=0 \
        DURATION="${CONCURRENCY_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        TEST_MODE=allowed \
        NO_CONNECTION_REUSE=false \
        SLEEP_MS="${CONCURRENCY_SLEEP_MS}"
    done
  done
}

run_saturation_suite() {
  local model="$1"
  local rate
  local run

  for rate in ${SATURATION_RATES}; do
    for run in $(seq 1 "${REPEATS}"); do
      msg "Saturation ${model}: RPS=${rate}, repetition=${run}/${REPEATS}"

      run_case "${model}" saturation.js \
        RUN_TAG="saturation-rps${rate}-run${run}" \
        VUS="${SATURATION_VUS}" \
        RPS="${rate}" \
        DURATION="${SATURATION_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        TEST_MODE=allowed \
        NO_CONNECTION_REUSE=false \
        SLEEP_MS=0
    done
  done
}

split_policy_rate() {
  local total="$1"
  local blocked_percent="$2"

  (( total >= 2 )) || die "Mixed policy test RPS must be at least 2"
  (( blocked_percent >= 1 && blocked_percent <= 99 )) || \
    die "Blocked traffic percentage must be between 1 and 99"

  BLOCKED_SPLIT=$((total * blocked_percent / 100))
  (( BLOCKED_SPLIT >= 1 )) || BLOCKED_SPLIT=1
  ALLOWED_SPLIT=$((total - BLOCKED_SPLIT))
  (( ALLOWED_SPLIT >= 1 )) || ALLOWED_SPLIT=1
}

run_l4_attack_suite() {
  local model="$1"
  local rate
  local run

  [[ "$(model_level "${model}")" == "l4" ]] || \
    die "The l4-attack suite requires calico-l4 or ambient-l4, not ${model}"

  for rate in ${L4_ATTACK_RATES}; do
    split_policy_rate "${rate}" "${L4_ATTACK_BLOCKED_PERCENT}"

    for run in $(seq 1 "${REPEATS}"); do
      msg "L4 attack ${model}: total=${rate} RPS, allowed=${ALLOWED_SPLIT}, blocked=${BLOCKED_SPLIT}, repetition=${run}/${REPEATS}"

      run_case "${model}" l4-attack.js \
        RUN_TAG="l4-attack-rps${rate}-blocked${L4_ATTACK_BLOCKED_PERCENT}-run${run}" \
        VUS="${L4_ATTACK_VUS}" \
        RPS="${rate}" \
        ALLOWED_RPS="${ALLOWED_SPLIT}" \
        BLOCKED_RPS="${BLOCKED_SPLIT}" \
        DURATION="${L4_ATTACK_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        BLOCKED_TARGET_URL=http://server:8081 \
        BLOCKED_METHOD=GET \
        BLOCKED_PATH=/health \
        TEST_MODE=l4-attack \
        SCENARIO_VARIANT="mixed-${L4_ATTACK_BLOCKED_PERCENT}pct-blocked" \
        NO_CONNECTION_REUSE=true \
        TIMEOUT="${L4_ATTACK_TIMEOUT}" \
        SLEEP_MS=0
    done
  done
}

run_l7_spaghetti_suite() {
  local model="$1"
  local variant
  local run

  [[ "$(model_level "${model}")" == "l7" ]] || \
    die "The l7-spaghetti suite requires calico-l7 or ambient-l7, not ${model}"

  split_policy_rate "${L7_SPAGHETTI_RPS}" "${L7_SPAGHETTI_BLOCKED_PERCENT}"
  ensure_model_ready "${model}"
  ACTIVE_L7_POLICY_MODEL="${model}"

  for variant in ${L7_SPAGHETTI_VARIANTS}; do
    case "${variant}" in
      simple)
        msg "Applying simple L7 control policy to ${model}"
        restore_simple_l7_policy "${model}"
        ;;
      spaghetti)
        msg "Applying complex L7 spaghetti policy to ${model}"
        apply_l7_spaghetti_policy "${model}"
        ;;
      *)
        die "Unknown L7 policy variant: ${variant}. Use simple and/or spaghetti"
        ;;
    esac

    sleep "${POLICY_SETTLE_SECONDS}"

    for run in $(seq 1 "${REPEATS}"); do
      msg "L7 rules ${model}: variant=${variant}, total=${L7_SPAGHETTI_RPS} RPS, repetition=${run}/${REPEATS}"

      run_case "${model}" l7-spaghetti.js \
        RUN_TAG="l7-${variant}-rps${L7_SPAGHETTI_RPS}-run${run}" \
        VUS="${L7_SPAGHETTI_VUS}" \
        RPS="${L7_SPAGHETTI_RPS}" \
        ALLOWED_RPS="${ALLOWED_SPLIT}" \
        BLOCKED_RPS="${BLOCKED_SPLIT}" \
        DURATION="${L7_SPAGHETTI_DURATION}" \
        TARGET_URL=http://server:8080 \
        REQUEST_METHOD=GET \
        REQUEST_PATH=/api/data \
        BLOCKED_TARGET_URL=http://server:8080 \
        BLOCKED_METHOD=POST \
        BLOCKED_PATH=/api/data \
        TEST_MODE=l7-spaghetti \
        SCENARIO_VARIANT="${variant}" \
        NO_CONNECTION_REUSE=false \
        TIMEOUT=3s \
        SLEEP_MS=0
    done
  done

  msg "Restoring simple L7 policy on ${model}"
  restore_simple_l7_policy "${model}"
  ACTIVE_L7_POLICY_MODEL=""
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

    concurrency)
      run_concurrency_suite "${model}"
      ;;

    saturation)
      run_saturation_suite "${model}"
      ;;

    l4-attack)
      if [[ "$(model_level "${model}")" == "l4" ]]; then
        run_l4_attack_suite "${model}"
      elif [[ "${MODEL_SELECTOR}" == "all" ]]; then
        msg "Skipping l4-attack for ${model}"
      else
        die "The l4-attack suite requires calico-l4 or ambient-l4, not ${model}"
      fi
      ;;

    l7-spaghetti)
      if [[ "$(model_level "${model}")" == "l7" ]]; then
        run_l7_spaghetti_suite "${model}"
      elif [[ "${MODEL_SELECTOR}" == "all" ]]; then
        msg "Skipping l7-spaghetti for ${model}"
      else
        die "The l7-spaghetti suite requires calico-l7 or ambient-l7, not ${model}"
      fi
      ;;

    all)
      run_verify_suite "${model}"
      run_steady_suite "${model}"
      run_churn_suite "${model}"
      run_concurrency_suite "${model}"
      run_saturation_suite "${model}"
      if [[ "$(model_level "${model}")" == "l4" ]]; then
        run_l4_attack_suite "${model}"
      fi
      if [[ "$(model_level "${model}")" == "l7" ]]; then
        run_l7_spaghetti_suite "${model}"
      fi
      ;;
  esac
done

msg "Benchmark suite finished"
