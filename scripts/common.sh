#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.logs"
TMP_DIR="${ROOT_DIR}/.tmp"
RESULTS_DIR="${ROOT_DIR}/results"

mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${RESULTS_DIR}"

K3D_IMAGE="${K3D_IMAGE:-rancher/k3s:v1.34.4-k3s1}"
K3D_SERVERS="${K3D_SERVERS:-1}"
K3D_AGENTS="${K3D_AGENTS:-1}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
APP_NS="${APP_NS:-test-app}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
DIKASTES_VERSION="${DIKASTES_VERSION:-v3.32}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
START_PORT_FORWARDS="${START_PORT_FORWARDS:-true}"

msg() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

check_base_tools() {
  require_bin bash
  require_bin kubectl
  require_bin k3d
  require_bin docker
  require_bin sed
  require_bin awk
}

check_istio_tools() {
  require_bin istioctl
}

check_monitoring_tools() {
  require_bin helm
}

check_result_tools() {
  require_bin python3
}

check_jq() {
  require_bin jq
}

model_cluster() {
  case "$1" in
    baseline|baseline-calico-ebpf)
      echo "baseline-calico-ebpf"
      ;;
    ambient-l4|istio-ambient-l4|l4)
      echo "istio-ambient-l4"
      ;;
    l7|l7-dikastes|istio-l7-dikastes|istio-sidecar-calico-l7-dikastes)
      echo "istio-l7-dikastes"
      ;;
    *)
      die "Unknown model: $1. Use: baseline, ambient-l4, l7-dikastes"
      ;;
  esac
}

model_short() {
  case "$1" in
    baseline|baseline-calico-ebpf)
      echo "baseline"
      ;;
    ambient-l4|istio-ambient-l4|l4)
      echo "ambient-l4"
      ;;
    l7|l7-dikastes|istio-l7-dikastes|istio-sidecar-calico-l7-dikastes)
      echo "l7-dikastes"
      ;;
    *)
      die "Unknown model: $1"
      ;;
  esac
}

cluster_exists() {
  local name="$1"
  k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$name"
}

container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -qx "$name"
}

wait_api_server() {
  local cluster_name="$1"
  local timeout="${2:-180}"
  local end_ts=$((SECONDS + timeout))

  msg "Waiting for Kubernetes API of ${cluster_name}"
  while (( SECONDS < end_ts )); do
    if kubectl config use-context "k3d-${cluster_name}" >/dev/null 2>&1 && kubectl get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  die "Kubernetes API did not become ready for ${cluster_name}"
}

create_cluster() {
  local name="$1"

  if cluster_exists "$name"; then
    msg "Cluster already exists: ${name}. Reusing it."
    use_cluster "$name"
    return 0
  fi

  msg "Creating k3d cluster ${name} without flannel, k3s network policy and kube-proxy"
  k3d cluster create "$name" \
    --image "${K3D_IMAGE}" \
    --servers "${K3D_SERVERS}" \
    --agents "${K3D_AGENTS}" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--disable-kube-proxy@server:*" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--cluster-cidr=${POD_CIDR}@server:*" \
    --k3s-arg "--service-cidr=${SERVICE_CIDR}@server:*"

  use_cluster "$name"
  wait_api_server "$name"
}

fix_kubeconfig_server_port() {
  local cluster_name="$1"
  local lb_container="k3d-${cluster_name}-serverlb"

  if ! container_exists "${lb_container}"; then
    warn "Load balancer container not found yet: ${lb_container}"
    return 0
  fi

  local port
  port="$(docker port "${lb_container}" 6443 2>/dev/null | sed 's/.*://')"

  if [[ -z "${port}" ]]; then
    warn "Could not determine mapped API port for ${lb_container}"
    return 0
  fi

  local kube_cluster_name
  kube_cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)"

  if [[ -z "${kube_cluster_name}" ]]; then
    warn "Could not determine current kubeconfig cluster name"
    return 0
  fi

  kubectl config set-cluster "${kube_cluster_name}" --server="https://127.0.0.1:${port}" >/dev/null
  msg "Kubeconfig API endpoint: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
}

use_cluster() {
  local name="$1"
  kubectl config use-context "k3d-${name}" >/dev/null
  fix_kubeconfig_server_port "$name"
}

stop_cluster() {
  local name="$1"
  if cluster_exists "$name"; then
    msg "Stopping cluster ${name}"
    k3d cluster stop "$name"
  else
    warn "Cluster does not exist: ${name}"
  fi
}

delete_cluster() {
  local name="$1"
  stop_model_port_forwards "$name" || true
  if cluster_exists "$name"; then
    msg "Deleting cluster ${name}"
    k3d cluster delete "$name"
  else
    warn "Cluster does not exist: ${name}"
  fi
}

ensure_namespace() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
}

label_namespace() {
  local ns="$1"
  shift
  ensure_namespace "$ns"
  kubectl label namespace "$ns" "$@" --overwrite
}

wait_pods_ready() {
  local ns="$1"
  local timeout="${2:-600s}"
  msg "Waiting for pods in namespace ${ns}"
  kubectl wait --for=condition=Ready pod --all -n "$ns" --timeout="${timeout}" || true
}

wait_tigerastatus() {
  msg "Waiting for Calico Tigerastatus resources"
  for name in apiserver calico; do
    kubectl wait --for=condition=Available "tigerastatus/${name}" --timeout=600s >/dev/null 2>&1 || true
  done
  kubectl get tigerastatus || true
}

install_calico_ebpf() {
  local connect_time_lb="${1:-TCP}"

  msg "Installing Calico Open Source ${CALICO_VERSION} with Tigera Operator"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

  msg "Enabling Calico container IP forwarding"
  kubectl patch installation.operator.tigera.io default --type merge \
    -p '{"spec":{"calicoNetwork":{"containerIPForwarding":"Enabled"}}}' || true

  msg "Enabling Calico eBPF dataplane"
  kubectl patch installation.operator.tigera.io default --type merge \
    -p '{"spec":{"calicoNetwork":{"linuxDataplane":"BPF"}}}'

  if [[ "${connect_time_lb}" == "Disabled" ]]; then
    msg "Disabling Calico BPF connect-time load balancing for Istio/Dikastes compatibility"
    kubectl patch felixconfiguration default --type merge \
      -p '{"spec":{"bpfConnectTimeLoadBalancing":"Disabled"}}' || true
  fi

  wait_tigerastatus
  wait_pods_ready calico-system 600s
}

verify_calico_ebpf() {
  msg "Calico eBPF verification"
  kubectl get installation.operator.tigera.io default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null || true
  echo
  kubectl get felixconfiguration default -o yaml 2>/dev/null | grep -E 'bpf|BPF|policySyncPathPrefix' || true
  kubectl logs -n calico-system ds/calico-node -c calico-node --tail=200 2>/dev/null | grep -E 'BPF|bpf|dataplane' || true
}

install_monitoring() {
  if [[ "${INSTALL_MONITORING}" != "true" ]]; then
    warn "Skipping monitoring installation because INSTALL_MONITORING=${INSTALL_MONITORING}"
    return 0
  fi

  check_monitoring_tools
  msg "Installing kube-prometheus-stack through Helm"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kps prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NS}" \
    --create-namespace \
    --wait \
    --timeout 15m \
    --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD:-admin}" \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false

  wait_pods_ready "${MONITORING_NS}" 600s
}

find_service_by_label() {
  local ns="$1"
  local label="$2"
  kubectl get svc -n "$ns" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

start_port_forward_bg() {
  local ns="$1"
  local svc="$2"
  local local_port="$3"
  local remote_port="$4"
  local name="$5"

  [[ -n "${svc}" ]] || die "Cannot start port-forward ${name}: service name is empty"

  stop_port_forward_if_exists "$name" || true

  local log_file="${LOG_DIR}/${name}.log"
  local pid_file="${LOG_DIR}/${name}.pid"

  msg "Starting port-forward ${name}: localhost:${local_port} -> ${ns}/svc/${svc}:${remote_port}"
  nohup kubectl -n "$ns" port-forward "svc/${svc}" "${local_port}:${remote_port}" >"${log_file}" 2>&1 &
  echo $! > "${pid_file}"
}

stop_port_forward_if_exists() {
  local name="$1"
  local pid_file="${LOG_DIR}/${name}.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" >/dev/null 2>&1; then
      msg "Stopping port-forward ${name}"
      kill "${pid}" || true
    fi
    rm -f "${pid_file}"
  fi
}

start_monitoring_port_forwards() {
  local model_name="$1"

  if [[ "${START_PORT_FORWARDS}" != "true" ]]; then
    return 0
  fi

  local grafana_svc
  grafana_svc="$(find_service_by_label "${MONITORING_NS}" 'app.kubernetes.io/name=grafana')"
  local prometheus_svc
  prometheus_svc="$(find_service_by_label "${MONITORING_NS}" 'app.kubernetes.io/name=prometheus')"

  if [[ -n "${grafana_svc}" ]]; then
    start_port_forward_bg "${MONITORING_NS}" "${grafana_svc}" 3000 80 "${model_name}-grafana"
  else
    warn "Grafana service not found"
  fi

  if [[ -n "${prometheus_svc}" ]]; then
    start_port_forward_bg "${MONITORING_NS}" "${prometheus_svc}" 9090 9090 "${model_name}-prometheus"
  else
    warn "Prometheus service not found"
  fi
}

stop_model_port_forwards() {
  local cluster_name="$1"
  stop_port_forward_if_exists "${cluster_name}-grafana" || true
  stop_port_forward_if_exists "${cluster_name}-prometheus" || true
}

apply_app() {
  local ns="$1"
  local mode="${2:-normal}"

  msg "Applying app manifests to namespace ${ns}, mode=${mode}"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/app-code-configmap.yaml"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/server-service.yaml"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/client-service.yaml"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/client-deployment.yaml"

  if [[ "${mode}" == "dikastes" ]]; then
    kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/server-deployment-dikastes.yaml"
  else
    kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/server-deployment.yaml"
  fi
}

apply_template() {
  local template_path="$1"
  shift
  local content
  content="$(cat "${template_path}")"
  content="${content//__APP_NS__/${APP_NS}}"
  content="${content//__DIKASTES_VERSION__/${DIKASTES_VERSION}}"
  content="${content//__CALICO_VERSION__/${CALICO_VERSION}}"
  printf '%s\n' "${content}" | kubectl apply -f -
}

apply_l4_policy() {
  local ns="$1"
  APP_NS="$ns" apply_template "${ROOT_DIR}/k8s/policies/calico-l4-client-to-server.yaml"
}

apply_l7_policy() {
  local ns="$1"
  APP_NS="$ns" apply_template "${ROOT_DIR}/k8s/policies/calico-l7-server-http-policy.yaml"
}

install_istio_ambient_l4() {
  check_istio_tools
  msg "Installing Istio ${ISTIO_VERSION} with ambient profile"
  istioctl install --set profile=ambient -y
  kubectl wait --for=condition=Ready pod --all -n istio-system --timeout=600s || true
}

install_istio_dikastes() {
  check_istio_tools

  msg "Enabling Calico Policy Sync API for Dikastes"
  kubectl patch felixconfiguration default --type merge -p '{"spec":{"policySyncPathPrefix":"/var/run/nodeagent"}}'
  kubectl patch installation default --type=merge -p '{"spec":{"flexVolumePath":"None"}}' || true
  kubectl patch felixconfiguration default --type merge -p '{"spec":{"bpfConnectTimeLoadBalancing":"Disabled"}}' || true

  msg "Rendering IstioOperator with Dikastes templates"
  local rendered="${TMP_DIR}/istio-operator-dikastes.yaml"
  sed \
    -e "s|__DIKASTES_VERSION__|${DIKASTES_VERSION}|g" \
    "${ROOT_DIR}/k8s/istio/istio-operator-dikastes.yaml.tmpl" > "${rendered}"

  msg "Installing Istio sidecar mode with Dikastes injection template"
  istioctl install -f "${rendered}" -y

  msg "Applying Calico Envoy external authorization resources"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/alp/istio-app-layer-policy-envoy-v3.yaml"
  kubectl wait --for=condition=Ready pod --all -n istio-system --timeout=600s || true
}

create_k6_configmap() {
  local ns="$1"
  msg "Creating/updating k6 ConfigMap in namespace ${ns}"
  kubectl create configmap k6-scripts \
    -n "${ns}" \
    --from-file="${ROOT_DIR}/k6" \
    --dry-run=client -o yaml | kubectl apply -f -
}

wait_job_deleted() {
  local ns="$1"
  local job_name="$2"

  for _ in $(seq 1 60); do
    if ! kubectl get job "$job_name" -n "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "Timed out waiting for job deletion: ${job_name} in namespace ${ns}"
}

run_k6_job_manifest() {
  local ns="$1"
  local job_name="$2"
  local k6_script="$3"

  msg "Recreating k6 job ${job_name} in namespace ${ns}"
  kubectl delete job "${job_name}" -n "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
  wait_job_deleted "$ns" "$job_name"

  sed \
    -e "s|__APP_NS__|${ns}|g" \
    -e "s|__JOB_NAME__|${job_name}|g" \
    -e "s|__K6_SCRIPT__|${k6_script}|g" \
    -e "s|__MODEL__|${K6_MODEL:-${ns}}|g" \
    -e "s|__VUS__|${VUS:-20}|g" \
    -e "s|__DURATION__|${DURATION:-30s}|g" \
    -e "s|__TARGET_URL__|${TARGET_URL:-http://client:8080/proxy}|g" \
    -e "s|__RPS__|${RPS:-0}|g" \
    -e "s|__PAYLOAD_SIZE__|${PAYLOAD_SIZE:-128}|g" \
    -e "s|__RESPONSE_SIZE__|${RESPONSE_SIZE:-128}|g" \
    -e "s|__REQUEST_METHOD__|${REQUEST_METHOD:-GET}|g" \
    -e "s|__REQUEST_PATH__|${REQUEST_PATH:-/api/data}|g" \
    -e "s|__TEST_MODE__|${TEST_MODE:-allowed}|g" \
    -e "s|__NO_CONNECTION_REUSE__|${NO_CONNECTION_REUSE:-false}|g" \
    -e "s|__SERVER_DELAY_MS__|${SERVER_DELAY_MS:-0}|g" \
    -e "s|__TIMEOUT__|${TIMEOUT:-5s}|g" \
    -e "s|__SLEEP_MS__|${SLEEP_MS:-100}|g" \
    -e "s|__FAIL_RATE_THRESHOLD__|${FAIL_RATE_THRESHOLD:-0.05}|g" \
    -e "s|__P95_THRESHOLD_MS__|${P95_THRESHOLD_MS:-1000}|g" \
    -e "s|__SUCCESS_RATE_THRESHOLD__|${SUCCESS_RATE_THRESHOLD:-0.95}|g" \
    "${ROOT_DIR}/k8s/k6/k6-job.yaml" | kubectl apply -f -
}

wait_k6_pod_created() {
  local ns="$1"
  local job_name="$2"

  for _ in $(seq 1 90); do
    local pod_name
    pod_name="$(kubectl get pods -n "$ns" -l job-name="$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pod_name}" ]]; then
      echo "${pod_name}"
      return 0
    fi
    sleep 1
  done

  die "Timed out waiting for k6 pod creation for job ${job_name}"
}

wait_for_pod_file() {
  local ns="$1"
  local pod_name="$2"
  local remote_path="$3"
  local timeout="${4:-600}"
  local end_ts=$((SECONDS + timeout))

  while (( SECONDS < end_ts )); do
    if kubectl exec -n "$ns" "$pod_name" -- sh -c "test -f '$remote_path'" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

copy_k6_result_file_if_exists() {
  local ns="$1"
  local pod_name="$2"
  local remote_path="$3"
  local local_path="$4"

  if kubectl exec -n "$ns" "$pod_name" -- sh -c "test -f '$remote_path'" >/dev/null 2>&1; then
    mkdir -p "$(dirname "${local_path}")"
    kubectl exec -n "$ns" "$pod_name" -- sh -c "cat '$remote_path'" > "${local_path}"
    msg "Saved file: ${local_path}"
  else
    warn "Result file not found in pod: ${remote_path}"
  fi
}

get_k6_vus_from_script() {
  local script_path="$1"
  local vus
  vus="$(grep -E 'const VUS|vus:' "${script_path}" 2>/dev/null | grep -Eo '[0-9]+' | head -n1 || true)"
  echo "${vus:-20}"
}

get_k6_duration_from_script() {
  local script_path="$1"
  local duration
  duration="$(grep -E "duration:" "${script_path}" 2>/dev/null | head -n1 | sed -E "s/.*duration:[[:space:]]*['\"]([^'\"]+)['\"].*/\1/" || true)"
  echo "${duration:-30s}"
}

safe_duration_tag() {
  echo "$1" | tr '/:' '__'
}

build_result_prefix() {
  local model_short="$1"
  local script_tag="$2"
  local vus="$3"
  local duration="$4"
  local run_tag="${5:-$(date +%Y%m%d-%H%M%S)}"
  local duration_tag
  duration_tag="$(safe_duration_tag "${duration}")"

  echo "${RESULTS_DIR}/${model_short}/${run_tag}-${model_short}-${script_tag}-vus${vus}-dur${duration_tag}"
}

print_ready_message() {
  local cluster_name="$1"
  local model="$2"
  echo
  msg "${model} is ready"
  echo "Context: k3d-${cluster_name}"
  echo "Namespace: ${APP_NS}"
  if [[ "${INSTALL_MONITORING}" == "true" ]]; then
    echo "Grafana:    http://localhost:3000  login: admin  password: ${GRAFANA_ADMIN_PASSWORD:-admin}"
    echo "Prometheus: http://localhost:9090"
  fi
}
