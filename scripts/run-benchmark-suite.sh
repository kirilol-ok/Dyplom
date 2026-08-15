#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes|all> <policy|steady|saturation|churn|concurrency|all>"
}
[[ $# -eq 2 ]] || { usage; exit 1; }

MODEL_SELECTOR="$1"
SUITE="$2"
TARGET_URL="${TARGET_URL:-http://server:8080}"
REPEATS="${REPEATS:-1}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
MAX_VUS="${MAX_VUS:-1500}"
BENCHMARK_VUS="${BENCHMARK_VUS:-500}"
RATES="${RATES:-500 1000 1500 2000 2500 3000 3500 4000 4500 5000}"
STEADY_DURATION="${STEADY_DURATION:-45s}"
POLICY_DURATION="${POLICY_DURATION:-15s}"
SATURATION_MAX_RPS="${SATURATION_MAX_RPS:-5000}"
SATURATION_STAGE_DURATION="${SATURATION_STAGE_DURATION:-20s}"
CHURN_RPS="${CHURN_RPS:-1000}"
CHURN_DURATION="${CHURN_DURATION:-45s}"
CONCURRENCY_VUS_LIST="${CONCURRENCY_VUS_LIST:-20 50 100 200 500}"
CONCURRENCY_DURATION="${CONCURRENCY_DURATION:-45s}"
BENCHMARK_CSV_FILE="${BENCHMARK_CSV_FILE:-${RESULTS_DIR}/benchmark-summary.csv}"

case "$MODEL_SELECTOR" in
  baseline|ambient-l4|l7-dikastes) MODELS=("$MODEL_SELECTOR") ;;
  all) MODELS=(baseline ambient-l4 l7-dikastes) ;;
  *) usage; exit 1 ;;
esac
case "$SUITE" in policy|steady|saturation|churn|concurrency|all) ;; *) usage; exit 1 ;; esac

server_local_healthy() {
  local pod=""
  pod="$(ready_pod_by_label "$APP_NS" "app=server" || true)"
  [[ -n "$pod" ]] || return 1

  kubectl exec -n "$APP_NS" "$pod" -c server -- \
    busybox wget -q -T 3 -O - http://127.0.0.1:8080/health >/dev/null
}

ensure_server_healthy() {
  local model="$1"
  local cluster
  cluster="$(model_cluster "$model")"
  use_cluster "$cluster"
  if server_local_healthy; then return 0; fi
  warn "Server process is unhealthy; restarting deployment/server"
  kubectl rollout restart deployment/server -n "$APP_NS" >/dev/null
  kubectl rollout status deployment/server -n "$APP_NS" --timeout=180s
  server_local_healthy || die "Server is still unhealthy after restart"
}

# Return the next run number for a logical test series.  This intentionally
# looks at the persistent CSV, so running the whole suite twice produces
# run1/run2 instead of a second run1/run1 pair.
next_run_index() {
  local model="$1"
  local tag_prefix="$2"

  python3 - "$BENCHMARK_CSV_FILE" "$model" "$tag_prefix" <<'PY'
import csv
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
model = sys.argv[2]
prefix = sys.argv[3]
pattern = re.compile(r"^" + re.escape(prefix) + r"-run(\d+)$")
maximum = 0
matched_rows = 0

if path.exists() and path.stat().st_size > 0:
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                if row.get("model") != model:
                    continue
                match = pattern.match(row.get("run_tag", ""))
                if match:
                    matched_rows += 1
                    maximum = max(maximum, int(match.group(1)))
    except (OSError, csv.Error, ValueError):
        pass

# Use both the largest explicit index and the number of historical rows.
# This prevents a new collision even if an older buggy run wrote run1 twice.
print(max(maximum, matched_rows) + 1)
PY
}

run_case() {
  local model="$1"
  local script="$2"
  shift 2
  ensure_server_healthy "$model"
  msg "Running ${script} for ${model}"
  local run_rc=0
  env TARGET_URL="$TARGET_URL" MAX_VUS="$MAX_VUS" BENCHMARK_CSV_FILE="$BENCHMARK_CSV_FILE" "$@" \
      bash "${ROOT_DIR}/scripts/run-k6.sh" "$model" "$script" || run_rc=$?

  case "$run_rc" in
    0)
      ;;
    20)
      warn "The k6 benchmark finished, but summary artifact collection failed. This is a runner/collection error, not a k6 threshold failure."
      ;;
    21)
      warn "The k6 benchmark finished and summary.json was saved, but local summary/CSV post-processing failed."
      ;;
    30)
      die "Ambient dataplane preflight failed before k6 started. Aborting the suite so invalid runs are not recorded."
      ;;
    *)
      warn "k6 exited with status ${run_rc}. If summary.json was collected, inspect thresholds and delivery metrics."
      ;;
  esac
  ensure_server_healthy "$model"
  (( COOLDOWN_SECONDS <= 0 )) || sleep "$COOLDOWN_SECONDS"
}

run_policy() {
  local model="$1"
  local mode prefix next
  for mode in allowed blocked admin-blocked mixed; do
    prefix="policy-${mode}"
    next="$(next_run_index "$model" "$prefix")"
    run_case "$model" policy-test.js \
      VUS=1 DURATION="$POLICY_DURATION" RPS=0 TEST_MODE="$mode" SLEEP_MS=100 \
      RUN_TAG="${prefix}-run${next}" RUN_INDEX="$next" \
      FAIL_RATE_THRESHOLD=0.001 SUCCESS_RATE_THRESHOLD=1 P95_THRESHOLD_MS=1000
  done
}

run_steady() {
  local model="$1"
  local rate run prefix first index
  for rate in $RATES; do
    prefix="steady-rps${rate}"
    first="$(next_run_index "$model" "$prefix")"
    for run in $(seq 0 $((REPEATS - 1))); do
      index=$((first + run))
      run_case "$model" steady-rps.js \
        VUS="$BENCHMARK_VUS" RPS="$rate" DURATION="$STEADY_DURATION" TEST_MODE=allowed SLEEP_MS=0 \
        RUN_TAG="${prefix}-run${index}" RUN_INDEX="$index"
    done
  done
}

run_saturation() {
  local model="$1"
  local prefix next
  prefix="saturation-max${SATURATION_MAX_RPS}"
  next="$(next_run_index "$model" "$prefix")"
  run_case "$model" saturation.js \
    VUS="$BENCHMARK_VUS" RPS="$SATURATION_MAX_RPS" DURATION="$SATURATION_STAGE_DURATION" \
    TEST_MODE=allowed SLEEP_MS=0 RUN_TAG="${prefix}-run${next}" RUN_INDEX="$next"
}

run_churn() {
  local model="$1"
  local reuse run prefix first index
  for reuse in false true; do
    prefix="churn-${reuse}"
    first="$(next_run_index "$model" "$prefix")"
    for run in $(seq 0 $((REPEATS - 1))); do
      index=$((first + run))
      run_case "$model" connection-churn.js \
        VUS="$BENCHMARK_VUS" RPS="$CHURN_RPS" DURATION="$CHURN_DURATION" TEST_MODE=allowed \
        NO_CONNECTION_REUSE="$reuse" SLEEP_MS=0 RUN_TAG="${prefix}-run${index}" RUN_INDEX="$index"
    done
  done
}

run_concurrency() {
  local model="$1"
  local vus run prefix first index
  for vus in $CONCURRENCY_VUS_LIST; do
    prefix="concurrency-vus${vus}"
    first="$(next_run_index "$model" "$prefix")"
    for run in $(seq 0 $((REPEATS - 1))); do
      index=$((first + run))
      run_case "$model" concurrency-vus.js \
        VUS="$vus" RPS=0 DURATION="$CONCURRENCY_DURATION" TEST_MODE=allowed SLEEP_MS=0 \
        RUN_TAG="${prefix}-run${index}" RUN_INDEX="$index"
    done
  done
}

for model in "${MODELS[@]}"; do
  case "$SUITE" in
    policy) run_policy "$model" ;;
    steady) run_steady "$model" ;;
    saturation) run_saturation "$model" ;;
    churn) run_churn "$model" ;;
    concurrency) run_concurrency "$model" ;;
    all) run_policy "$model"; run_steady "$model"; run_saturation "$model"; run_churn "$model"; run_concurrency "$model" ;;
  esac
done

msg "Benchmark suite finished"
msg "Summary CSV: ${BENCHMARK_CSV_FILE}"
msg "Resource CSV: ${RESULTS_DIR}/benchmark-resources.csv"
