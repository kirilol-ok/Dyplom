#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes> [script.js]"
  exit 1
fi

MODEL_SHORT="$(model_short "$1")"
CLUSTER_NAME="$(model_cluster "$MODEL_SHORT")"
K6_SCRIPT="${2:-steady-rps.js}"
[[ -f "${ROOT_DIR}/k6/${K6_SCRIPT}" ]] || die "K6 script not found: ${K6_SCRIPT}"

JOB_NAME="${JOB_NAME:-k6-test}"
TARGET_URL="${TARGET_URL:-http://server:8080}"
VUS="${VUS:-500}"
MAX_VUS="${MAX_VUS:-1500}"
DURATION="${DURATION:-45s}"
RPS="${RPS:-0}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-0}"
RESPONSE_SIZE="${RESPONSE_SIZE:-128}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
REQUEST_PATH="${REQUEST_PATH:-/api/data}"
TEST_MODE="${TEST_MODE:-allowed}"
NO_CONNECTION_REUSE="${NO_CONNECTION_REUSE:-false}"
SERVER_DELAY_MS="${SERVER_DELAY_MS:-0}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-5s}"
SLEEP_MS="${SLEEP_MS:-0}"
FAIL_RATE_THRESHOLD="${FAIL_RATE_THRESHOLD:-0.01}"
P95_THRESHOLD_MS="${P95_THRESHOLD_MS:-1000}"
SUCCESS_RATE_THRESHOLD="${SUCCESS_RATE_THRESHOLD:-0.99}"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d-%H%M%S)}"
RUN_INDEX="${RUN_INDEX:-1}"
BENCHMARK_CSV_ENABLED="${BENCHMARK_CSV_ENABLED:-true}"
BENCHMARK_CSV_FILE="${BENCHMARK_CSV_FILE:-${RESULTS_DIR}/benchmark-summary.csv}"
RESOURCE_CSV_ENABLED="${RESOURCE_CSV_ENABLED:-true}"
RESOURCE_CSV_FILE="${RESOURCE_CSV_FILE:-${RESULTS_DIR}/benchmark-resources.csv}"
RESOURCE_SAMPLE_INTERVAL="${RESOURCE_SAMPLE_INTERVAL:-5}"

SAFE_TAG="$(printf '%s' "$RUN_TAG" | tr -cs '[:alnum:]_.-' '-')"
SAFE_DURATION="$(printf '%s' "$DURATION" | tr -cs '[:alnum:]_.-' '-')"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${RESULTS_DIR}/${MODEL_SHORT}"
mkdir -p "$OUT_DIR"
PREFIX="${OUT_DIR}/${TS}-${MODEL_SHORT}-${K6_SCRIPT%.js}-${SAFE_TAG}-vus${VUS}-dur${SAFE_DURATION}"
LOG_FILE="${PREFIX}.log"
SUMMARY_FILE="${PREFIX}-summary.json"
RENDERED_JOB="${TMP_DIR}/${JOB_NAME}.yaml"
RESOURCE_PID=""
LOG_PID=""
CGROUP_FILE="${PREFIX}-cgroup.json"
PREFLIGHT_LOG="${PREFIX}-ambient-preflight.log"
SERVER_POD=""
K6_CGROUP_START=""
K6_CGROUP_END=""
SERVER_CGROUP_START=""
SERVER_CGROUP_END=""

render_job() {
  local job_template="${ROOT_DIR}/k8s/k6/k6-job.yaml"
  if [[ "$MODEL_SHORT" == ambient-l4 ]]; then
    job_template="${ROOT_DIR}/k8s/k6/k6-job-ambient.yaml"
  fi

  sed \
    -e "s|__JOB_NAME__|${JOB_NAME}|g" \
    -e "s|__APP_NS__|${APP_NS}|g" \
    -e "s|__K6_SCRIPT__|${K6_SCRIPT}|g" \
    -e "s|__MODEL__|${MODEL_SHORT}|g" \
    -e "s|__TARGET_URL__|${TARGET_URL}|g" \
    -e "s|__VUS__|${VUS}|g" \
    -e "s|__MAX_VUS__|${MAX_VUS}|g" \
    -e "s|__DURATION__|${DURATION}|g" \
    -e "s|__RPS__|${RPS}|g" \
    -e "s|__PAYLOAD_SIZE__|${PAYLOAD_SIZE}|g" \
    -e "s|__RESPONSE_SIZE__|${RESPONSE_SIZE}|g" \
    -e "s|__REQUEST_METHOD__|${REQUEST_METHOD}|g" \
    -e "s|__REQUEST_PATH__|${REQUEST_PATH}|g" \
    -e "s|__TEST_MODE__|${TEST_MODE}|g" \
    -e "s|__NO_CONNECTION_REUSE__|${NO_CONNECTION_REUSE}|g" \
    -e "s|__SERVER_DELAY_MS__|${SERVER_DELAY_MS}|g" \
    -e "s|__REQUEST_TIMEOUT__|${REQUEST_TIMEOUT}|g" \
    -e "s|__SLEEP_MS__|${SLEEP_MS}|g" \
    -e "s|__FAIL_RATE_THRESHOLD__|${FAIL_RATE_THRESHOLD}|g" \
    -e "s|__P95_THRESHOLD_MS__|${P95_THRESHOLD_MS}|g" \
    -e "s|__SUCCESS_RATE_THRESHOLD__|${SUCCESS_RATE_THRESHOLD}|g" \
    "$job_template" > "$RENDERED_JOB"
}

copy_summary() {
  local pod="$1"
  local tmp="${SUMMARY_FILE}.tmp"
  rm -f "$tmp"
  for attempt in 1 2 3 4 5; do
    kubectl exec -n "$APP_NS" "$pod" -c k6 -- sh -c 'cat /results/summary.json' > "$tmp" 2>/dev/null || true
    if [[ -s "$tmp" ]] && python3 -m json.tool "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$SUMMARY_FILE"
      return 0
    fi
    warn "summary copy attempt ${attempt}/5 failed"
    rm -f "$tmp"
    sleep 1
  done
  return 1
}


read_cgroup_cpu_stat() {
  local pod="$1"
  local container="$2"

  kubectl exec -n "$APP_NS" "$pod" -c "$container" -- sh -c '
    version=""
    usage="NA"
    nr_periods="NA"
    nr_throttled="NA"
    throttled_usec="NA"

    if [ -r /sys/fs/cgroup/cpu.stat ]; then
      version=2
      while read -r key value; do
        case "$key" in
          usage_usec) usage="$value" ;;
          nr_periods) nr_periods="$value" ;;
          nr_throttled) nr_throttled="$value" ;;
          throttled_usec) throttled_usec="$value" ;;
        esac
      done < /sys/fs/cgroup/cpu.stat
    else
      stat_path=""
      for candidate in /sys/fs/cgroup/cpu/cpu.stat /sys/fs/cgroup/cpu,cpuacct/cpu.stat; do
        if [ -r "$candidate" ]; then stat_path="$candidate"; break; fi
      done
      [ -n "$stat_path" ] || exit 3
      version=1
      throttled_ns="NA"
      while read -r key value; do
        case "$key" in
          nr_periods) nr_periods="$value" ;;
          nr_throttled) nr_throttled="$value" ;;
          throttled_time) throttled_ns="$value" ;;
        esac
      done < "$stat_path"
      if [ "$throttled_ns" != "NA" ]; then throttled_usec=$((throttled_ns / 1000)); fi
      for usage_path in /sys/fs/cgroup/cpuacct/cpuacct.usage /sys/fs/cgroup/cpu,cpuacct/cpuacct.usage; do
        if [ -r "$usage_path" ]; then
          usage_ns="$(cat "$usage_path")"
          usage=$((usage_ns / 1000))
          break
        fi
      done
    fi

    printf "%s|%s|%s|%s|%s\n" "$version" "$usage" "$nr_periods" "$nr_throttled" "$throttled_usec"
  ' 2>/dev/null | tr -d '\r' | tail -n1
}

write_cgroup_report() {
  python3 - "$CGROUP_FILE" "$MODEL_SHORT" "${K6_SCRIPT%.js}" "$RUN_TAG" "$RUN_INDEX" "$RPS" \
    "$K6_CGROUP_START" "$K6_CGROUP_END" "$SERVER_CGROUP_START" "$SERVER_CGROUP_END" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, model, profile, run_tag, run_index, target_rps, k6_start, k6_end, server_start, server_end = sys.argv[1:]

def parse(raw):
    parts = (raw or '').strip().split('|')
    if len(parts) != 5:
        return None
    version, usage, periods, throttled, throttled_usec = parts
    def n(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return None
    return {
        'cgroup_version': n(version),
        'usage_usec': n(usage),
        'nr_periods': n(periods),
        'nr_throttled': n(throttled),
        'throttled_usec': n(throttled_usec),
    }

def build(start_raw, end_raw):
    start = parse(start_raw)
    end = parse(end_raw)
    keys = ('usage_usec', 'nr_periods', 'nr_throttled', 'throttled_usec')
    if start and end and start.get('cgroup_version') == end.get('cgroup_version'):
        delta = {
            key: None if start.get(key) is None or end.get(key) is None
            else max(0, end[key] - start[key])
            for key in keys
        }
    else:
        delta = {key: None for key in keys}
    periods = delta.get('nr_periods')
    throttled = delta.get('nr_throttled')
    delta['throttled_period_pct'] = (
        None if not periods or throttled is None else 100.0 * throttled / periods
    )
    return {'start': start, 'end': end, 'delta': delta}

report = {
    'schema_version': 1,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
    'model': model,
    'profile': profile,
    'run_tag': run_tag,
    'run_index': run_index,
    'target_rps': target_rps,
    'k6': build(k6_start, k6_end),
    'server': build(server_start, server_end),
}
Path(out).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
PY
}

sample_resources() {
  local pod="$1"
  [[ "$RESOURCE_CSV_ENABLED" == true ]] || return 0
  if ! kubectl top pod -n "$APP_NS" --containers --no-headers >/dev/null 2>&1; then
    warn "Metrics API unavailable; resource sampling disabled for this run"
    return 0
  fi
  mkdir -p "$(dirname "$RESOURCE_CSV_FILE")"
  if [[ ! -s "$RESOURCE_CSV_FILE" ]]; then
    echo 'timestamp_utc,model,profile,run_tag,run_index,target_rps,namespace,pod,container,cpu_mcores,memory_mib' > "$RESOURCE_CSV_FILE"
  fi
  (
    while true; do
      local_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      emit_top() {
        local ns="$1"
        local mode="$2"
        kubectl top pod -n "$ns" --containers --no-headers 2>/dev/null \
          | awk -v ts="$local_ts" -v model="$MODEL_SHORT" -v profile="${K6_SCRIPT%.js}" \
              -v tag="$RUN_TAG" -v run="$RUN_INDEX" -v rps="$RPS" -v ns="$ns" -v k6pod="$pod" -v mode="$mode" '
              function cpu(v,n) {
                n=v; if (v ~ /n$/) {sub(/n$/, "", n); return n/1000000}
                if (v ~ /u$/) {sub(/u$/, "", n); return n/1000}
                if (v ~ /m$/) {sub(/m$/, "", n); return n+0}
                return (n+0)*1000
              }
              function mem(v,n) {
                n=v; if (v ~ /Ki$/) {sub(/Ki$/, "", n); return n/1024}
                if (v ~ /Mi$/) {sub(/Mi$/, "", n); return n+0}
                if (v ~ /Gi$/) {sub(/Gi$/, "", n); return n*1024}
                return n+0
              }
              mode == "app" && ($1 == k6pod || $1 ~ /^server-/) {keep=1}
              mode == "calico" && $1 ~ /^calico-node-/ {keep=1}
              mode == "calico_ambient" && ($1 ~ /^calico-node-/ || $1 ~ /^ztunnel-/ || $1 ~ /^istiod-/ || $1 ~ /^istio-cni-node-/) {keep=1}
              mode == "istio" && ($1 ~ /^ztunnel-/ || $1 ~ /^istiod-/ || $1 ~ /^istio-proxy-/) {keep=1}
              keep {
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%.6f,%.6f\n", ts,model,profile,tag,run,rps,ns,$1,$2,cpu($3),mem($4)
                keep=0
              }' >> "$RESOURCE_CSV_FILE" || true
      }

      emit_top "$APP_NS" app
      if kubectl get ns calico-system >/dev/null 2>&1; then
        if [[ "$MODEL_SHORT" == ambient-l4 ]]; then
          # Calico-managed Ambient runs calico-node, ztunnel and istiod in
          # calico-system. Collect them in one top call to keep sampling
          # overhead low. Baseline keeps its original calico-only sampling.
          emit_top calico-system calico_ambient
        else
          emit_top calico-system calico
        fi
      fi
      if [[ "$MODEL_SHORT" == l7-dikastes ]] && kubectl get ns istio-system >/dev/null 2>&1; then
        emit_top istio-system istio
      fi
      sleep "$RESOURCE_SAMPLE_INTERVAL"
    done
  ) &
  RESOURCE_PID=$!
}
cleanup_bg() {
  [[ -z "$RESOURCE_PID" ]] || kill "$RESOURCE_PID" >/dev/null 2>&1 || true
  [[ -z "$LOG_PID" ]] || kill "$LOG_PID" >/dev/null 2>&1 || true
}
trap cleanup_bg EXIT

ambient_k6_preflight() {
  local pod="$1"

  check_istio_tools
  msg "Waiting for k6 workload to be enrolled in Ambient HBONE"
  if ! wait_ambient_workload_hbone "$APP_NS" "$pod" 180; then
    kubectl logs -n "$APP_NS" "$pod" -c ambient-preflight > "$PREFLIGHT_LOG" 2>&1 || true
    warn "k6 pod was not enrolled as HBONE. Init log: ${PREFLIGHT_LOG}"
    istioctl ztunnel-config workloads -n calico-system >&2 || true
    kubectl describe pod "$pod" -n "$APP_NS" >&2 || true
    return 1
  fi

  # The init container independently waits until Istio reports
  # ambient.istio.io/redirection=enabled through a Downward API volume, then
  # performs five consecutive Service checks from the exact k6 Pod network
  # namespace. No kubectl exec signal is needed, avoiding a race with init
  # container startup.
  if ! kubectl wait --for=condition=Ready "pod/${pod}" -n "$APP_NS" --timeout=240s >/dev/null 2>&1; then
    kubectl logs -n "$APP_NS" "$pod" -c ambient-preflight > "$PREFLIGHT_LOG" 2>&1 || true
    warn "Ambient k6 preflight failed. Log: ${PREFLIGHT_LOG}"
    kubectl describe pod "$pod" -n "$APP_NS" >&2 || true
    kubectl logs -n calico-system -l app.kubernetes.io/name=ztunnel --since=2m --prefix >&2 || true
    return 1
  fi

  kubectl logs -n "$APP_NS" "$pod" -c ambient-preflight > "$PREFLIGHT_LOG" 2>&1 || true
  if ! kubectl exec -n "$APP_NS" "$pod" -c k6 -- sh -c 'test -f /results/.ambient-ready' >/dev/null 2>&1; then
    warn "Ambient preflight init completed without the ready marker. Log: ${PREFLIGHT_LOG}"
    return 1
  fi

  if ! wait_ambient_workload_hbone "$APP_NS" "$pod" 30; then
    warn "k6 pod lost HBONE enrollment after preflight"
    return 1
  fi

  msg "Ambient k6 preflight passed (redirection enabled + HBONE + 5/5 Service checks)"
  return 0
}

check_base_tools
check_result_tools
if [[ "$MODEL_SHORT" == ambient-l4 ]]; then
  check_istio_tools
fi
use_cluster "$CLUSTER_NAME"
create_k6_configmap "$APP_NS"

msg "Model: ${MODEL_SHORT}"
msg "Target: ${TARGET_URL}"
msg "Script: ${K6_SCRIPT}, VUS=${VUS}, MAX_VUS=${MAX_VUS}, RPS=${RPS}, DURATION=${DURATION}"
msg "Results: ${PREFIX}*"

kubectl delete job "$JOB_NAME" -n "$APP_NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
render_job
kubectl apply -f "$RENDERED_JOB" >/dev/null

POD=""
for _ in $(seq 1 120); do
  POD="$(kubectl get pod -n "$APP_NS" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "$POD" ]] || break
  sleep 1
done
[[ -n "$POD" ]] || die "k6 pod was not created"

msg "k6 pod: ${POD}"
if [[ "$MODEL_SHORT" == ambient-l4 ]]; then
  if ! ambient_k6_preflight "$POD"; then
    warn "Ambient k6 dataplane preflight failed; benchmark was not started"
    kubectl delete job "$JOB_NAME" -n "$APP_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    exit 30
  fi
else
  # Keep baseline/L7 startup semantics unchanged.
  kubectl wait --for=condition=Ready "pod/${POD}" -n "$APP_NS" --timeout=180s >/dev/null
fi

# The k6 container waits on /results/.start. Capture true pre-run cpu.stat
# counters only after any Ambient preflight traffic has completed, so the
# preflight does not contaminate benchmark throttling/usage deltas.
SERVER_POD="$(ready_pod_by_label "$APP_NS" "app=server" || true)"
K6_CGROUP_START="$(read_cgroup_cpu_stat "$POD" k6 || true)"
if [[ -n "$SERVER_POD" ]]; then
  SERVER_CGROUP_START="$(read_cgroup_cpu_stat "$SERVER_POD" server || true)"
fi
[[ -n "$K6_CGROUP_START" ]] || warn "Could not read initial k6 cpu.stat"
[[ -n "$SERVER_CGROUP_START" ]] || warn "Could not read initial server cpu.stat"

(kubectl logs -f -n "$APP_NS" "$POD" -c k6 2>&1 | tee "$LOG_FILE") &
LOG_PID=$!

msg "Starting k6 benchmark"
kubectl exec -n "$APP_NS" "$POD" -c k6 -- sh -c 'touch /results/.start' >/dev/null
sample_resources "$POD"

wait_for_k6_finished_marker() {
  local pod="$1"

  # Keep one exec session open instead of creating multiple kubectl exec
  # sessions every second while the benchmark is running.  The k6 wrapper
  # creates .k6-finished only after `k6 run` and handleSummary have returned.
  kubectl exec -n "$APP_NS" "$pod" -c k6 -- sh -c '
    i=0
    while [ ! -f /results/.k6-finished ] && [ "$i" -lt 900 ]; do
      i=$((i + 1))
      sleep 1
    done
    test -f /results/.k6-finished
  ' >/dev/null 2>&1
}

msg "Waiting for k6 benchmark completion"
FINISHED=false
if wait_for_k6_finished_marker "$POD"; then
  FINISHED=true
else
  # A dropped exec stream should not discard a completed benchmark.  Perform
  # one fallback check only after the marker wait has failed; do not poll the
  # container with repeated exec calls during the measured interval.
  if kubectl exec -n "$APP_NS" "$POD" -c k6 -- sh -c 'test -s /results/summary.json' >/dev/null 2>&1; then
    FINISHED=true
    warn "k6 marker wait failed, but summary.json is present; collecting completed results"
  fi
fi

[[ "$FINISHED" == true ]] || warn "k6 finished marker/summary was not observed"

K6_CGROUP_END="$(read_cgroup_cpu_stat "$POD" k6 || true)"
if [[ -n "$SERVER_POD" ]]; then
  SERVER_CGROUP_END="$(read_cgroup_cpu_stat "$SERVER_POD" server || true)"
fi
[[ -n "$K6_CGROUP_END" ]] || warn "Could not read final k6 cpu.stat"
[[ -n "$SERVER_CGROUP_END" ]] || warn "Could not read final server cpu.stat"
write_cgroup_report
msg "Saved cgroup CPU report: ${CGROUP_FILE}"

# Stop resource sampling as soon as the measured interval has ended.  Keep
# the log follower alive until the k6 wrapper exits so final threshold and
# wrapper messages are not reordered or truncated.
if [[ -n "$RESOURCE_PID" ]]; then
  kill "$RESOURCE_PID" >/dev/null 2>&1 || true
  wait "$RESOURCE_PID" >/dev/null 2>&1 || true
  RESOURCE_PID=""
fi

COPY_OK=false
POSTPROCESS_OK=true
if copy_summary "$POD"; then
  COPY_OK=true
  msg "Saved summary: ${SUMMARY_FILE}"
  if [[ "$BENCHMARK_CSV_ENABLED" == true ]]; then
    if ! python3 "${ROOT_DIR}/scripts/pretty-summary.py" "$SUMMARY_FILE" \
      --csv "$BENCHMARK_CSV_FILE" \
      --cgroup-json "$CGROUP_FILE" \
      --run-tag "$RUN_TAG" --run-index "$RUN_INDEX" --script "$K6_SCRIPT"; then
      POSTPROCESS_OK=false
      warn "Summary was saved, but CSV post-processing failed"
    fi
  else
    if ! python3 "${ROOT_DIR}/scripts/pretty-summary.py" "$SUMMARY_FILE" \
      --cgroup-json "$CGROUP_FILE" \
      --run-tag "$RUN_TAG" --run-index "$RUN_INDEX" --script "$K6_SCRIPT"; then
      POSTPROCESS_OK=false
      warn "Summary was saved, but summary post-processing failed"
    fi
  fi
else
  warn "Could not copy a valid summary.json"
fi

# Always release the k6 wrapper after artifact collection, even when the
# local post-processing step fails.
for _ in 1 2 3; do
  kubectl exec -n "$APP_NS" "$POD" -c k6 -- sh -c 'touch /results/.copied' >/dev/null 2>&1 && break
  sleep 1
done

EXIT_CODE=""
for _ in $(seq 1 60); do
  EXIT_CODE="$(kubectl get pod "$POD" -n "$APP_NS" -o jsonpath='{.status.containerStatuses[?(@.name=="k6")].state.terminated.exitCode}' 2>/dev/null || true)"
  [[ -n "$EXIT_CODE" ]] && break
  sleep 1
done
EXIT_CODE="${EXIT_CODE:-1}"

if [[ -n "$LOG_PID" ]]; then
  wait "$LOG_PID" >/dev/null 2>&1 || true
  LOG_PID=""
fi

# Exit 20 means the benchmark ran, but the summary artifact could not be
# collected. Exit 21 means the raw summary was collected successfully, but
# local CSV/pretty-summary processing failed. Keep both distinct from the
# actual k6 exit code.
[[ "$COPY_OK" == true ]] || exit 20
[[ "$POSTPROCESS_OK" == true ]] || exit 21
exit "$EXIT_CODE"
