#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CHECK_RPS="${CHECK_RPS:-500}"
CHECK_VUS="${CHECK_VUS:-400}"
CHECK_DURATION="${CHECK_DURATION:-45s}"
SETTLE_SECONDS="${SETTLE_SECONDS:-30}"
CHECK_REPEATS="${CHECK_REPEATS:-1}"

if [[ -n "${CHECK_MODELS:-}" ]]; then
  read -r -a MODELS <<< "${CHECK_MODELS}"
else
  mapfile -t MODELS < <(all_models)
fi

check_base_tools
REPORT_DIR="${RESULTS_DIR}/architecture-check-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${REPORT_DIR}"
REPORT_CSV="${REPORT_DIR}/check-report.csv"
ACTIVE_MODEL=""

stop_active_model() {
  if [[ -n "${ACTIVE_MODEL}" ]]; then
    msg "Stopping ${ACTIVE_MODEL} (cluster is preserved)"
    bash "${SCRIPT_DIR}/down.sh" "${ACTIVE_MODEL}" soft || warn "Could not stop ${ACTIVE_MODEL}"
    ACTIVE_MODEL=""
  fi
}
trap stop_active_model EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

previous_count() {
  python3 - "${RESULTS_DIR}/benchmark-summary.csv" "$1" <<'PY'
import csv, os, sys
path, model = sys.argv[1:]
if not os.path.isfile(path):
    print(0)
else:
    with open(path, newline='', encoding='utf-8-sig') as f:
        print(sum(row.get('model') == model for row in csv.DictReader(f)))
PY
}

append_report() {
  local model="$1" before="$2" stage="$3"
  python3 - "${RESULTS_DIR}/benchmark-summary.csv" "${REPORT_CSV}" "$model" "$before" "$stage" "$CHECK_RPS" <<'PY'
import csv, os, sys
summary, report, model, before, stage, target = sys.argv[1:]
before, target = int(before), float(target)
fields = ['model', 'status', 'policy_verify', 'achieved_rps', 'http_p95_ms',
          'http_p99_ms', 'dropped_iterations', 'http_failed_pct',
          'expected_status_pct', 'server_cpu_limit', 'config_id', 'run_id']
rows = []
if os.path.isfile(summary):
    with open(summary, newline='', encoding='utf-8-sig') as f:
        rows = [r for r in csv.DictReader(f) if r.get('model') == model][before:]

def num(row, field, default=0.0):
    try:
        return float(row.get(field, ''))
    except (ValueError, TypeError):
        return default

verifications = [r for r in rows if r.get('profile') == 'policy-verify']
verify_ok = len(verifications) >= 2 and all(num(r, 'expected_status_pct', -1) >= 99.9 for r in verifications)
steady = [r for r in rows if r.get('profile') == 'steady-rps' and abs(num(r, 'configured_rps') - target) < .01]
row = steady[-1] if steady else {}
steady_ok = (bool(steady) and num(row, 'achieved_rps') >= target * .98
             and num(row, 'dropped_iterations', -1) == 0
             and num(row, 'http_failed_pct', 100) < .1
             and num(row, 'expected_status_pct', -1) >= 99.9)
status = 'OK' if stage == 'completed' and verify_ok and steady_ok else 'REVIEW'
if stage != 'completed':
    status = stage.upper()
result = {
    'model': model, 'status': status,
    'policy_verify': f'{sum(num(r, "expected_status_pct", -1) >= 99.9 for r in verifications)}/{len(verifications)}',
    'achieved_rps': row.get('achieved_rps', ''), 'http_p95_ms': row.get('http_p95_ms', ''),
    'http_p99_ms': row.get('http_p99_ms', ''),
    'dropped_iterations': row.get('dropped_iterations', ''),
    'http_failed_pct': row.get('http_failed_pct', ''),
    'expected_status_pct': row.get('expected_status_pct', ''),
    'server_cpu_limit': row.get('server_cpu_limit', ''),
    'config_id': row.get('config_id', ''), 'run_id': row.get('run_id', ''),
}
with open(report, 'a', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    if f.tell() == 0:
        writer.writeheader()
    writer.writerow(result)
print(f'[CHECK] {model}: {status}; policy={result["policy_verify"]}; '
      f'RPS={result["achieved_rps"]}; p95={result["http_p95_ms"]}; '
      f'dropped={result["dropped_iterations"]}')
PY
}

msg "Running a sequential check: ${MODELS[*]}"
msg "RPS=${CHECK_RPS}, preallocated VUs=${CHECK_VUS}, duration=${CHECK_DURATION}, repeats=${CHECK_REPEATS}"
msg "Reports: ${REPORT_DIR}"

for requested_model in "${MODELS[@]}"; do
  model="$(canonical_model "${requested_model}")"
  cluster="$(model_cluster "${model}")"
  log="${REPORT_DIR}/${model}.log"
  before="$(previous_count "${model}")"

  echo
  msg "========== ${model} =========="
  ACTIVE_MODEL="${model}"

  # up.sh reuses existing clusters but does not start stopped clusters.
  if cluster_exists "${cluster}" && ! docker ps --format '{{.Names}}' | grep -Fxq "k3d-${cluster}-server-0"; then
    if ! k3d cluster start "${cluster}" 2>&1 | tee -a "${log}"; then
      append_report "${model}" "${before}" start_failed
      stop_active_model
      continue
    fi
  fi

  # Redeploy the model so that current YAML templates and policies are applied.
  if ! bash "${SCRIPT_DIR}/up.sh" "${model}" 2>&1 | tee -a "${log}"; then
    append_report "${model}" "${before}" setup_failed
    stop_active_model
    continue
  fi

  # Actual container resources (including components installed by operators).
  kubectl get pods -A -o wide > "${REPORT_DIR}/${model}-pods.txt" 2>&1 || true
  kubectl get pods -A -o json > "${REPORT_DIR}/${model}-pods.json" 2>&1 || true
  kubectl get pods -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,POD:.metadata.name,CONTAINERS:.spec.containers[*].name,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu,MEM_REQUEST:.spec.containers[*].resources.requests.memory,MEM_LIMIT:.spec.containers[*].resources.limits.memory' \
    > "${REPORT_DIR}/${model}-limits.txt" 2>&1 || true

  msg "Settling ${model} for ${SETTLE_SECONDS}s"
  sleep "${SETTLE_SECONDS}"

  stage="completed"
  if ! bash "${SCRIPT_DIR}/run-benchmark-suite.sh" "${model}" verify 2>&1 | tee -a "${log}"; then
    stage="verify_failed"
  fi

  if ! env RATES="${CHECK_RPS}" REPEATS="${CHECK_REPEATS}" \
      BENCHMARK_VUS="${CHECK_VUS}" STEADY_DURATION="${CHECK_DURATION}" \
      bash "${SCRIPT_DIR}/run-benchmark-suite.sh" "${model}" steady 2>&1 | tee -a "${log}"; then
    stage="steady_failed"
  fi

  append_report "${model}" "${before}" "${stage}"
  stop_active_model
 done

msg "Checks finished. Review: ${REPORT_CSV}"
msg "Main CSVs: ${RESULTS_DIR}/benchmark-summary.csv, benchmark-resources.csv"
