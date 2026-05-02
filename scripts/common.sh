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
    # Do not use /readyz here. A fresh k3s cluster without CNI can report
    # NotReady until Calico is installed, but the API is already usable.
    if kubectl config use-context "k3d-${cluster_name}" >/dev/null 2>&1 \
      && kubectl --request-timeout=5s get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  warn "Kubernetes API check failed for ${cluster_name}. Diagnostics:"
  kubectl config current-context 2>/dev/null || true
  kubectl get --raw=/livez 2>/dev/null || true
  kubectl get --raw=/readyz?verbose 2>/dev/null || true
  kubectl get nodes -o wide 2>/dev/null || true
  die "Kubernetes API did not become reachable for ${cluster_name}"
}

create_cluster() {
  local name="$1"

  if cluster_exists "$name"; then
    msg "Cluster already exists: ${name}. Reusing it."
    use_cluster "$name"
    return 0
  fi

  msg "Creating k3d cluster ${name}"

  k3d cluster create "$name" \
    --image "${K3D_IMAGE}" \
    --servers 1 \
    --agents 1 \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--tls-san=10.43.0.1@server:*" \
    --wait

  use_cluster "$name"
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
  local cluster_name="${1:-}"
  local calico_version="${CALICO_VERSION:-v3.32.0}"

  msg "Installing Calico Open Source ${calico_version} with Tigera Operator"

  msg "Installing Calico operator CRDs with server-side apply"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/v1_crd_projectcalico_org.yaml"

  msg "Waiting for Calico operator CRDs"
  kubectl wait --for=condition=Established \
    crd/installations.operator.tigera.io \
    --timeout=180s

  kubectl wait --for=condition=Established \
    crd/apiservers.operator.tigera.io \
    --timeout=180s

  msg "Installing Tigera Operator"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/tigera-operator.yaml"

  msg "Waiting for Tigera Operator deployment"
  kubectl rollout status deployment/tigera-operator \
    -n tigera-operator \
    --timeout=300s

  msg "Installing Calico custom resources in standard mode first"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/custom-resources.yaml"

  msg "Waiting for Calico namespace"
  wait_namespace_exists "calico-system" 300

  msg "Waiting for Calico resources to be created"
  wait_resource_exists "daemonset/calico-node" "calico-system" 300
  wait_resource_exists "deployment/calico-kube-controllers" "calico-system" 300

  msg "Waiting for Calico node daemonset in standard mode"
  kubectl rollout status daemonset/calico-node \
    -n calico-system \
    --timeout=600s

  msg "Waiting for Kubernetes nodes to become Ready in standard mode"
  kubectl wait --for=condition=Ready nodes --all --timeout=600s

  msg "Waiting for Calico kube controllers in standard mode"
  kubectl rollout status deployment/calico-kube-controllers \
    -n calico-system \
    --timeout=600s

  msg "Waiting for nodes to become Ready before eBPF switch"
  kubectl wait --for=condition=Ready nodes --all --timeout=600s

  msg "Adjusting Calico eBPF settings for k3d/k3s"

  kubectl patch installation.operator.tigera.io default --type merge -p '{
    "spec": {
      "calicoNetwork": {
        "linuxDataplane": "BPF",
        "kubeProxyManagement": "Disabled"
      }
    }
  }'

  kubectl patch felixconfiguration default --type merge -p '{
    "spec": {
      "bpfKubeProxyHealthzPort": 0,
      "bpfKubeProxyIptablesCleanupEnabled": false
    }
  }'

  msg "Waiting for Calico components after eBPF switch"
  kubectl rollout status daemonset/calico-node \
    -n calico-system \
    --timeout=600s

  kubectl rollout status deployment/calico-kube-controllers \
    -n calico-system \
    --timeout=600s

  msg "Waiting for nodes to stay Ready after eBPF switch"
  kubectl wait --for=condition=Ready nodes --all --timeout=600s

  msg "Calico eBPF installation status"
  kubectl get nodes -o wide
  kubectl get pods -n calico-system
  kubectl get tigerastatus || true

  msg "Checking eBPF dataplane setting"
  kubectl get installation.operator.tigera.io default \
    -o jsonpath='{.spec.calicoNetwork.linuxDataplane}{"\n"}'

  msg "Checking kube-proxy management setting"
  kubectl get installation.operator.tigera.io default \
    -o jsonpath='{.spec.calicoNetwork.kubeProxyManagement}{"\n"}'
}

verify_calico_ebpf() {
  msg "Calico eBPF verification"
  kubectl get installation.operator.tigera.io default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null || true
  echo
  kubectl get felixconfiguration default -o yaml 2>/dev/null | grep -E 'bpf|BPF|policySyncPathPrefix' || true
  kubectl logs -n calico-system ds/calico-node -c calico-node --tail=200 2>/dev/null | grep -E 'BPF|bpf|dataplane' || true
}

wait_namespace_exists() {
  local ns="$1"
  local timeout="${2:-300}"
  local end_ts=$((SECONDS + timeout))

  msg "Waiting for namespace ${ns}"

  while (( SECONDS < end_ts )); do
    if kubectl get ns "${ns}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  warn "Namespace ${ns} was not created in ${timeout}s"
  warn "Tigera Operator diagnostics:"
  kubectl get installation default -o yaml 2>/dev/null || true
  kubectl describe installation default 2>/dev/null || true
  kubectl logs -n tigera-operator deployment/tigera-operator --tail=200 2>/dev/null || true

  die "Namespace ${ns} was not created"
}

install_monitoring() {
  if [[ "${INSTALL_MONITORING}" != "true" ]]; then
    warn "Skipping monitoring installation because INSTALL_MONITORING=${INSTALL_MONITORING}"
    return 0
  fi

  ensure_namespace "${MONITORING_NS}"

  kubectl delete job -n "${MONITORING_NS}" \
    kps-kube-prometheus-stack-admission-create \
    kps-kube-prometheus-stack-admission-patch \
    --ignore-not-found=true || true
    
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
  prometheus_svc="$(kubectl get svc -n "${MONITORING_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^kps-kube-prometheus-stack-prometheus$|prometheus-kps-kube-prometheus-stack-prometheus$|prometheus-operated$' \
    | head -n1 || true)"

  if [[ -z "${prometheus_svc}" ]]; then
    prometheus_svc="$(kubectl get svc -n "${MONITORING_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -Ei 'prometheus' \
      | grep -Eiv 'alertmanager|node-exporter|operator|webhook' \
      | head -n1 || true)"
  fi

  if [[ -n "${grafana_svc}" ]]; then
    start_port_forward_bg "${MONITORING_NS}" "${grafana_svc}" 3000 80 "${model_name}-grafana"
  else
    warn "Grafana service not found"
    kubectl get svc -n "${MONITORING_NS}" || true
  fi

  if [[ -n "${prometheus_svc}" ]]; then
    start_port_forward_bg "${MONITORING_NS}" "${prometheus_svc}" 9090 9090 "${model_name}-prometheus"
  else
    warn "Prometheus service not found"
    kubectl get svc -n "${MONITORING_NS}" || true
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
  local vus=""

  # Supports:
  # vus: 20
  # vus: Number(__ENV.VUS || 20)
  # vus: Number(__ENV.VUS || '20')
  vus="$(grep -E 'vus:[[:space:]]*([0-9]+|Number\(__ENV\.VUS[[:space:]]*\|\|[[:space:]]*'\''?[0-9]+'\''?\))' "${script_path}" 2>/dev/null \
    | head -n1 \
    | sed -E "s/.*vus:[[:space:]]*([0-9]+).*/\1/; t; s/.*__ENV\.VUS[[:space:]]*\|\|[[:space:]]*'?'?([0-9]+)'?'?.*/\1/" || true)"

  if [[ -z "${vus}" || "${vus}" == *"vus:"* ]]; then
    vus="20"
  fi

  echo "${vus}"
}

get_k6_duration_from_script() {
  local script_path="$1"
  local duration=""

  # Supports:
  # duration: '30s'
  # duration: __ENV.DURATION || '30s'
  # duration: String(__ENV.DURATION || '30s')
  duration="$(grep -E "duration:[[:space:]]*(__ENV\.DURATION|String\(__ENV\.DURATION|['\"][^'\"]+['\"])" "${script_path}" 2>/dev/null \
    | head -n1 \
    | sed -E "s/.*__ENV\.DURATION[[:space:]]*\|\|[[:space:]]*['\"]([^'\"]+)['\"].*/\1/; t; s/.*duration:[[:space:]]*['\"]([^'\"]+)['\"].*/\1/" || true)"

  if [[ -z "${duration}" || "${duration}" == *"duration:"* || "${duration}" == *"__ENV"* ]]; then
    duration="30s"
  fi

  echo "${duration}"
}

safe_duration_tag() {
  echo "$1" | tr '/:' '__'
}

build_result_prefix() {
  local model="$1"
  local script_tag="$2"
  local vus="$3"
  local duration="$4"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  local safe_duration
  safe_duration="$(echo "${duration}" | tr -c 'A-Za-z0-9_.-' '_')"

  mkdir -p "${RESULTS_DIR}/${model}"

  echo "${RESULTS_DIR}/${model}/${ts}-${model}-${script_tag}-vus${vus}-dur${safe_duration}"
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

configure_tigera_direct_api_access() {
  local cluster_name="$1"
  local lb_container="k3d-${cluster_name}-serverlb"
  local server_container="k3d-${cluster_name}-server-0"
  local api_ip=""

  msg "Configuring Tigera Operator direct Kubernetes API access"

  if docker ps --format '{{.Names}}' | grep -qx "${lb_container}"; then
    api_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${lb_container}" 2>/dev/null || true)"
  fi

  if [[ -z "${api_ip}" ]] && docker ps --format '{{.Names}}' | grep -qx "${server_container}"; then
    api_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${server_container}" 2>/dev/null || true)"
  fi

  if [[ -z "${api_ip}" ]]; then
    die "Could not determine k3d API container IP for ${cluster_name}"
  fi

  msg "Using direct API endpoint for Tigera Operator: ${api_ip}:6443"

  kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n tigera-operator create configmap kubernetes-services-endpoint \
    --from-literal=KUBERNETES_SERVICE_HOST="${api_ip}" \
    --from-literal=KUBERNETES_SERVICE_PORT="6443" \
    --dry-run=client -o yaml | kubectl apply -f -
}

wait_resource_exists() {
  local resource="$1"
  local namespace="$2"
  local timeout="${3:-300}"
  local end_ts=$((SECONDS + timeout))

  msg "Waiting for ${resource} in namespace ${namespace}"

  while (( SECONDS < end_ts )); do
    if kubectl get "${resource}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  warn "Timed out waiting for ${resource} in namespace ${namespace}"
  kubectl get pods -n "${namespace}" -o wide 2>/dev/null || true
  die "Resource did not appear: ${resource}"
}
