#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"
  exit 1
fi

MODEL="$1"
CLUSTER="$(model_cluster "${MODEL}")"
APP_NAMESPACE="${APP_NAMESPACE:-${APP_NS}}"
CLIENT_DEPLOYMENT="${CLIENT_DEPLOYMENT:-client}"
SERVER_DEPLOYMENT="${SERVER_DEPLOYMENT:-server}"
RPS="${RPS:-200}"
DURATION="${DURATION:-2m}"
REPEATS="${REPEATS:-3}"
BENCHMARK_VUS="${BENCHMARK_VUS:-200}"
TARGET_URL="${TARGET_URL:-http://client:8080/proxy}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"

check_jq
use_cluster "${CLUSTER}"

mapfile -t NODES < <(
  kubectl get nodes -o json | jq -r '
    .items[]
    | select(.spec.unschedulable != true)
    | select(([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length) == 0)
    | .metadata.name
  '
)

if (( ${#NODES[@]} < 2 )); then
  die "Topology test needs at least two schedulable nodes. Increase K3D_AGENTS if necessary."
fi

NODE_A="${NODE_A:-${NODES[0]}}"
NODE_B="${NODE_B:-${NODES[1]}}"

client_selector="$(kubectl get deployment "${CLIENT_DEPLOYMENT}" -n "${APP_NAMESPACE}" -o json | jq -c '.spec.template.spec.nodeSelector // null')"
server_selector="$(kubectl get deployment "${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" -o json | jq -c '.spec.template.spec.nodeSelector // null')"

restore_selector() {
  local deployment="$1"
  local selector="$2"
  kubectl patch deployment "${deployment}" -n "${APP_NAMESPACE}" --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":${selector}}}}}" >/dev/null 2>&1 || true
}

cleanup() {
  restore_selector "${CLIENT_DEPLOYMENT}" "${client_selector}"
  restore_selector "${SERVER_DEPLOYMENT}" "${server_selector}"
  kubectl rollout status deployment/"${CLIENT_DEPLOYMENT}" -n "${APP_NAMESPACE}" --timeout=600s >/dev/null 2>&1 || true
  kubectl rollout status deployment/"${SERVER_DEPLOYMENT}" -n "${APP_NAMESPACE}" --timeout=600s >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

place_deployment() {
  local deployment="$1"
  local node="$2"
  kubectl patch deployment "${deployment}" -n "${APP_NAMESPACE}" --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${node}\"}}}}}"
  kubectl rollout status deployment/"${deployment}" -n "${APP_NAMESPACE}" --timeout=600s
}

run_topology() {
  local topology="$1"
  local client_node="$2"
  local server_node="$3"
  local run

  msg "Topology ${topology}: client=${client_node}, server=${server_node}"
  place_deployment "${CLIENT_DEPLOYMENT}" "${client_node}"
  place_deployment "${SERVER_DEPLOYMENT}" "${server_node}"

  for run in $(seq 1 "${REPEATS}"); do
    if ! env \
      MODEL="${MODEL}" \
      RUN_TAG="topology-${topology}-run${run}" \
      VUS="${BENCHMARK_VUS}" \
      RPS="${RPS}" \
      DURATION="${DURATION}" \
      TARGET_URL="${TARGET_URL}" \
      TEST_MODE=allowed \
      SLEEP_MS=0 \
      bash "${ROOT_DIR}/scripts/run-k6.sh" "${MODEL}" steady-rps.js; then
      warn "The k6 run failed a threshold for topology=${topology}"
    fi

    if (( COOLDOWN_SECONDS > 0 )); then
      sleep "${COOLDOWN_SECONDS}"
    fi
  done
}

run_topology same-node "${NODE_A}" "${NODE_A}"
run_topology cross-node "${NODE_A}" "${NODE_B}"
