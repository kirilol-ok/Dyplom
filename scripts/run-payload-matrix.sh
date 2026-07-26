#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"
  exit 1
fi

MODEL="$1"
SIZES="${SIZES:-128 16384 262144}"
RPS="${RPS:-200}"
DURATION="${DURATION:-2m}"
REPEATS="${REPEATS:-3}"
BENCHMARK_VUS="${BENCHMARK_VUS:-200}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"

for size in ${SIZES}; do
  for run in $(seq 1 "${REPEATS}"); do
    msg "Payload test ${MODEL}: request=${size} B, response=${size} B, run=${run}/${REPEATS}"

    if ! env \
      MODEL="${MODEL}" \
      RUN_TAG="payload-${size}-run${run}" \
      VUS="${BENCHMARK_VUS}" \
      RPS="${RPS}" \
      DURATION="${DURATION}" \
      TARGET_URL="${TARGET_URL}" \
      TEST_MODE=allowed \
      PAYLOAD_SIZE="${size}" \
      RESPONSE_SIZE="${size}" \
      SLEEP_MS=0 \
      bash "${ROOT_DIR}/scripts/run-k6.sh" "${MODEL}" steady-rps.js; then
      warn "The k6 run failed a threshold for size=${size}"
    fi

    if (( COOLDOWN_SECONDS > 0 )); then
      sleep "${COOLDOWN_SECONDS}"
    fi
  done
done
