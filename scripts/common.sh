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
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
APP_IMAGE="${APP_IMAGE:-diploma-benchmark-app-go:v2}"
REBUILD_APP_IMAGE="${REBUILD_APP_IMAGE:-false}"

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
  require_bin python3
}

check_istio_tools() {
  require_bin istioctl
  local client_version
  client_version="$(istioctl version --remote=false 2>/dev/null | head -n1 || true)"
  [[ -n "${client_version}" ]] && msg "istioctl client: ${client_version}"
  if [[ -n "${EXPECTED_ISTIOCTL_VERSION:-}" && "${client_version}" != *"${EXPECTED_ISTIOCTL_VERSION}"* ]]; then
    warn "Expected istioctl ${EXPECTED_ISTIOCTL_VERSION}, found: ${client_version}"
  fi
}

canonical_model() {
  case "${1:-}" in
    calico-baseline|baseline|baseline-calico-ebpf)
      echo "calico-baseline"
      ;;
    calico-l4|calico-l4-policy)
      echo "calico-l4"
      ;;
    calico-l7|calico-l7-dikastes|l7-dikastes|istio-l7-dikastes|istio-sidecar-calico-l7-dikastes)
      echo "calico-l7"
      ;;
    ambient-baseline|istio-ambient-baseline|ambient-base)
      echo "ambient-baseline"
      ;;
    ambient-l4|istio-ambient-l4)
      echo "ambient-l4"
      ;;
    ambient-l7|ambient-waypoint|istio-ambient-l7|istio-ambient-l7-waypoint)
      echo "ambient-l7"
      ;;
    l4)
      die "Alias 'l4' is ambiguous now. Use calico-l4 or ambient-l4"
      ;;
    *)
      die "Unknown model: ${1:-<empty>}. Use calico-baseline, calico-l4, calico-l7, ambient-baseline, ambient-l4, ambient-l7"
      ;;
  esac
}

model_cluster() {
  case "$(canonical_model "$1")" in
    calico-baseline) echo "diploma-calico-baseline" ;;
    calico-l4) echo "diploma-calico-l4" ;;
    calico-l7) echo "diploma-calico-l7-dikastes" ;;
    ambient-baseline) echo "diploma-ambient-baseline" ;;
    ambient-l4) echo "diploma-ambient-l4" ;;
    ambient-l7) echo "diploma-ambient-l7-waypoint" ;;
  esac
}

model_family() {
  case "$(canonical_model "$1")" in
    calico-*) echo "calico" ;;
    ambient-*) echo "ambient" ;;
  esac
}

model_level() {
  case "$(canonical_model "$1")" in
    *-baseline) echo "baseline" ;;
    *-l4) echo "l4" ;;
    *-l7) echo "l7" ;;
  esac
}

all_models() {
  printf '%s\n' \
    calico-baseline \
    calico-l4 \
    calico-l7 \
    ambient-baseline \
    ambient-l4 \
    ambient-l7
}

cluster_exists() {
  local name="${1:-}"
  [[ -n "${name}" ]] || return 1
  k3d cluster list --no-headers 2>/dev/null \
    | awk -v expected="${name}" '$1 == expected { found = 1 } END { exit !found }'
}

container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -qx "${name}"
}

fix_kubeconfig_server_port() {
  local cluster_name="$1"
  local lb_container="k3d-${cluster_name}-serverlb"
  local port=""
  local kube_cluster_name=""

  container_exists "${lb_container}" || return 0
  port="$(docker port "${lb_container}" 6443 2>/dev/null | head -n1 | sed 's/.*://')"
  [[ -n "${port}" ]] || return 0

  kube_cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
  [[ -n "${kube_cluster_name}" ]] || return 0

  kubectl config set-cluster "${kube_cluster_name}" --server="https://127.0.0.1:${port}" >/dev/null
}

use_cluster() {
  local name="$1"
  kubectl config use-context "k3d-${name}" >/dev/null
  fix_kubeconfig_server_port "${name}"
}

wait_api_server() {
  local cluster_name="$1"
  local timeout="${2:-180}"
  local end_ts=$((SECONDS + timeout))

  msg "Waiting for Kubernetes API of ${cluster_name}"
  while (( SECONDS < end_ts )); do
    if kubectl config use-context "k3d-${cluster_name}" >/dev/null 2>&1 \
      && kubectl --request-timeout=5s get nodes >/dev/null 2>&1; then
      fix_kubeconfig_server_port "${cluster_name}"
      return 0
    fi
    sleep 2
  done
  die "Kubernetes API did not become reachable for ${cluster_name}"
}

create_cluster() {
  local name="$1"

  if cluster_exists "${name}"; then
    msg "Cluster already exists: ${name}. Reusing it."
    use_cluster "${name}"
    return 0
  fi

  msg "Creating k3d cluster ${name}"
  k3d cluster create "${name}" \
    --image "${K3D_IMAGE}" \
    --servers "${K3D_SERVERS}" \
    --agents "${K3D_AGENTS}" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--disable-kube-proxy@server:*" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --k3s-arg "--cluster-cidr=${POD_CIDR}@server:*" \
    --k3s-arg "--service-cidr=${SERVICE_CIDR}@server:*" \
    --wait

  wait_api_server "${name}" 180
}

stop_cluster() {
  local name="$1"
  if cluster_exists "${name}"; then
    msg "Stopping cluster ${name}"
    k3d cluster stop "${name}"
  else
    warn "Cluster does not exist: ${name}"
  fi
}

delete_cluster() {
  local name="$1"
  if cluster_exists "${name}"; then
    msg "Deleting cluster ${name}"
    k3d cluster delete "${name}"
  else
    warn "Cluster does not exist: ${name}"
  fi
}

wait_namespace_exists() {
  local ns="$1"
  local timeout="${2:-300}"
  local end_ts=$((SECONDS + timeout))
  while (( SECONDS < end_ts )); do
    kubectl get namespace "${ns}" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_resource_exists() {
  local resource="$1"
  local namespace="${2:-}"
  local timeout="${3:-300}"
  local end_ts=$((SECONDS + timeout))
  while (( SECONDS < end_ts )); do
    if [[ -n "${namespace}" ]]; then
      kubectl get "${resource}" -n "${namespace}" >/dev/null 2>&1 && return 0
    else
      kubectl get "${resource}" >/dev/null 2>&1 && return 0
    fi
    sleep 2
  done
  return 1
}

ensure_namespace() {
  local ns="$1"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

reset_app_namespace() {
  if kubectl get namespace "${APP_NS}" >/dev/null 2>&1; then
    msg "Resetting namespace ${APP_NS} for a clean model state"
    kubectl delete namespace "${APP_NS}" --wait=true --timeout=180s >/dev/null
  fi
  ensure_namespace "${APP_NS}"
}

label_namespace() {
  local ns="$1"
  shift
  ensure_namespace "${ns}"
  kubectl label namespace "${ns}" "$@" --overwrite >/dev/null
}

configure_tigera_direct_api_access() {
  local cluster_name="$1"
  local server_container="k3d-${cluster_name}-server-0"
  local network_name="k3d-${cluster_name}"
  local api_ip=""

  api_ip="$(docker inspect --format "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "${server_container}" 2>/dev/null || true)"
  [[ -n "${api_ip}" ]] || die "Could not determine direct Kubernetes API IP for ${cluster_name}"

  kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n tigera-operator create configmap kubernetes-services-endpoint \
    --from-literal=KUBERNETES_SERVICE_HOST="${api_ip}" \
    --from-literal=KUBERNETES_SERVICE_PORT="6443" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

configure_calico_direct_api_env() {
  local cluster_name="$1"
  local server_container="k3d-${cluster_name}-server-0"
  local network_name="k3d-${cluster_name}"
  local api_ip=""

  api_ip="$(docker inspect --format "{{with index .NetworkSettings.Networks \"${network_name}\"}}{{.IPAddress}}{{end}}" "${server_container}" 2>/dev/null || true)"
  [[ -n "${api_ip}" ]] || die "Could not determine API server IP for ${cluster_name}"

  kubectl set env deployment/calico-kube-controllers -n calico-system \
    KUBERNETES_SERVICE_HOST="${api_ip}" KUBERNETES_SERVICE_PORT="6443" >/dev/null
  kubectl set env deployment/calico-apiserver -n calico-system \
    KUBERNETES_SERVICE_HOST="${api_ip}" KUBERNETES_SERVICE_PORT="6443" >/dev/null
}

wait_calico_core() {
  msg "Waiting for Calico core components"
  wait_resource_exists daemonset/calico-node calico-system 300 || die "calico-node was not created"
  wait_resource_exists deployment/calico-kube-controllers calico-system 300 || die "calico-kube-controllers was not created"
  wait_resource_exists deployment/calico-apiserver calico-system 300 || die "calico-apiserver was not created"

  kubectl rollout status daemonset/calico-node -n calico-system --timeout=600s
  kubectl rollout status deployment/calico-kube-controllers -n calico-system --timeout=600s
  kubectl rollout status deployment/calico-apiserver -n calico-system --timeout=600s
  kubectl wait --for=condition=Ready nodes --all --timeout=600s
}

install_calico_ebpf() {
  local cluster_name="$1"
  use_cluster "${cluster_name}"

  msg "Installing Calico Open Source ${CALICO_VERSION} with eBPF dataplane"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v1_crd_projectcalico_org.yaml"

  kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=180s
  kubectl wait --for=condition=Established crd/apiservers.operator.tigera.io --timeout=180s

  configure_tigera_direct_api_access "${cluster_name}"

  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
  kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=300s

  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

  wait_resource_exists installation.operator.tigera.io/default "" 180 || die "Calico Installation/default was not created"

  local installation_patch
  installation_patch="$(cat <<JSON
{
  "spec": {
    "controlPlaneReplicas": 1,
    "calicoNetwork": {
      "linuxDataplane": "BPF",
      "bpfNetworkBootstrap": "Disabled",
      "kubeProxyManagement": "Disabled",
      "ipPools": [
        {
          "name": "default-ipv4-ippool",
          "blockSize": 26,
          "cidr": "${POD_CIDR}",
          "encapsulation": "VXLANCrossSubnet",
          "natOutgoing": "Enabled",
          "nodeSelector": "all()"
        }
      ]
    }
  }
}
JSON
)"

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "${installation_patch}" | jq -e . >/dev/null \
      || die "Generated Calico Installation patch is not valid JSON"
  fi

  kubectl patch installation.operator.tigera.io default --type merge -p "${installation_patch}"

  wait_namespace_exists calico-system 300 || die "calico-system namespace was not created"
  wait_resource_exists felixconfiguration/default "" 300 || die "FelixConfiguration/default was not created"

  kubectl patch felixconfiguration default --type merge -p '{
    "spec": {
      "bpfKubeProxyHealthzPort": 0,
      "bpfKubeProxyIptablesCleanupEnabled": false
    }
  }'

  wait_resource_exists deployment/calico-kube-controllers calico-system 300 || true
  wait_resource_exists deployment/calico-apiserver calico-system 300 || true
  configure_calico_direct_api_env "${cluster_name}"
  wait_calico_core

  msg "Calico eBPF is ready"
  kubectl get nodes -o wide
}

configure_calico_for_istio() {
  msg "Disabling Calico eBPF connect-time load balancing for Istio compatibility"
  kubectl patch felixconfiguration default --type merge \
    -p '{"spec":{"bpfConnectTimeLoadBalancing":"Disabled"}}'

  local value=""
  for _ in $(seq 1 60); do
    value="$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfConnectTimeLoadBalancing}' 2>/dev/null || true)"
    [[ "${value}" == "Disabled" ]] && break
    sleep 2
  done
  [[ "${value}" == "Disabled" ]] || die "Failed to set bpfConnectTimeLoadBalancing=Disabled"
}

install_istio_ambient() {
  check_istio_tools
  configure_calico_for_istio
  msg "Installing Istio Ambient profile"
  istioctl install --set profile=ambient -y
  wait_resource_exists daemonset/ztunnel istio-system 300 || die "ztunnel was not created"
  kubectl rollout status daemonset/ztunnel -n istio-system --timeout=600s
  kubectl rollout status deployment/istiod -n istio-system --timeout=600s
}

install_gateway_api_crds() {
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    msg "Gateway API CRDs already installed"
    return 0
  fi

  msg "Installing Gateway API ${GATEWAY_API_VERSION} CRDs"
  kubectl apply --server-side \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
  kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=180s
}

install_istio_dikastes() {
  check_istio_tools
  configure_calico_for_istio

  msg "Enabling Calico Policy Sync API for Dikastes"
  kubectl patch felixconfiguration default --type merge \
    -p '{"spec":{"policySyncPathPrefix":"/var/run/nodeagent"}}'
  kubectl patch installation.operator.tigera.io default --type merge \
    -p '{"spec":{"flexVolumePath":"None"}}' || true

  local rendered="${TMP_DIR}/istio-operator-dikastes.yaml"
  sed "s|__CALICO_VERSION__|${CALICO_VERSION}|g" \
    "${ROOT_DIR}/k8s/istio/istio-operator-dikastes.yaml.tmpl" > "${rendered}"

  msg "Installing Istio sidecar mode with Dikastes injection template"
  istioctl install -f "${rendered}" -y
  kubectl rollout status deployment/istiod -n istio-system --timeout=600s

  msg "Applying Calico Envoy external authorization integration"
  kubectl apply \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/alp/istio-app-layer-policy-envoy-v3.yaml"
}

build_and_import_app_image() {
  local cluster_name="$1"

  if [[ "${REBUILD_APP_IMAGE}" == "true" ]] || ! docker image inspect "${APP_IMAGE}" >/dev/null 2>&1; then
    msg "Building benchmark app image ${APP_IMAGE}"
    docker build -t "${APP_IMAGE}" "${ROOT_DIR}/app"
  else
    msg "Using existing local app image ${APP_IMAGE}"
  fi

  msg "Importing ${APP_IMAGE} into ${cluster_name}"
  k3d image import -c "${cluster_name}" "${APP_IMAGE}" >/dev/null
}

render_and_apply() {
  local template="$1"
  local rendered="${TMP_DIR}/$(basename "${template}" .tmpl).rendered.yaml"

  sed \
    -e "s|__APP_NS__|${APP_NS}|g" \
    -e "s|__APP_IMAGE__|${APP_IMAGE}|g" \
    -e "s|__CALICO_VERSION__|${CALICO_VERSION}|g" \
    "${template}" > "${rendered}"

  kubectl apply -n "${APP_NS}" -f "${rendered}"
}

apply_app() {
  local mode="${1:-normal}"
  ensure_namespace "${APP_NS}"

  kubectl apply -n "${APP_NS}" -f "${ROOT_DIR}/k8s/app/serviceaccounts.yaml"
  kubectl apply -n "${APP_NS}" -f "${ROOT_DIR}/k8s/app/server-service.yaml"
  kubectl apply -n "${APP_NS}" -f "${ROOT_DIR}/k8s/app/client-service.yaml"
  render_and_apply "${ROOT_DIR}/k8s/app/client-deployment.yaml.tmpl"

  if [[ "${mode}" == "dikastes" ]]; then
    render_and_apply "${ROOT_DIR}/k8s/app/server-deployment-dikastes.yaml.tmpl"
  else
    render_and_apply "${ROOT_DIR}/k8s/app/server-deployment.yaml.tmpl"
  fi
}

apply_policy_file() {
  local path="$1"
  sed "s|__APP_NS__|${APP_NS}|g" "${path}" | kubectl apply -f -
}

apply_calico_l4_policy() {
  apply_policy_file "${ROOT_DIR}/k8s/policies/calico-l4.yaml"
}

apply_calico_l7_policy() {
  apply_policy_file "${ROOT_DIR}/k8s/policies/calico-l7.yaml"
}

apply_ambient_l4_policy() {
  apply_policy_file "${ROOT_DIR}/k8s/policies/istio-ambient-l4.yaml"
}

apply_ambient_l7_policy() {
  apply_policy_file "${ROOT_DIR}/k8s/policies/istio-ambient-l7.yaml"
}

apply_l7_spaghetti_policy() {
  local model
  model="$(canonical_model "$1")"

  case "${model}" in
    calico-l7)
      apply_policy_file "${ROOT_DIR}/k8s/policies/calico-l7-spaghetti.yaml"
      ;;
    ambient-l7)
      apply_policy_file "${ROOT_DIR}/k8s/policies/istio-ambient-l7-spaghetti.yaml"
      ;;
    *)
      die "L7 spaghetti policy is supported only for calico-l7 and ambient-l7"
      ;;
  esac
}

restore_simple_l7_policy() {
  local model
  model="$(canonical_model "$1")"

  case "${model}" in
    calico-l7)
      apply_calico_l7_policy
      ;;
    ambient-l7)
      kubectl delete authorizationpolicy server-l7-spaghetti-deny \
        -n "${APP_NS}" --ignore-not-found >/dev/null
      apply_ambient_l7_policy
      ;;
    *)
      die "Simple L7 policy restore is supported only for calico-l7 and ambient-l7"
      ;;
  esac
}

create_waypoint_for_server() {
  install_gateway_api_crds
  msg "Creating and enrolling the server waypoint"
  istioctl waypoint apply -n "${APP_NS}" \
    --name server-waypoint \
    --for service \
    --enroll-namespace \
    --wait

  kubectl wait --for=condition=Programmed gateway/server-waypoint \
    -n "${APP_NS}" --timeout=300s

  local enrolled_waypoint=""
  enrolled_waypoint="$(kubectl get namespace "${APP_NS}" \
    -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')"
  [[ "${enrolled_waypoint}" == "server-waypoint" ]] \
    || die "Namespace ${APP_NS} is not enrolled in server-waypoint"
}

wait_app_ready() {
  msg "Waiting for application deployments"

  if ! kubectl get deployment/server -n "${APP_NS}" >/dev/null 2>&1; then
    warn "server deployment is not present in namespace ${APP_NS}"
    kubectl get deployment -A -o wide || true
    die "server deployment was created in the wrong namespace or was not created"
  fi

  if ! kubectl get deployment/client -n "${APP_NS}" >/dev/null 2>&1; then
    warn "client deployment is not present in namespace ${APP_NS}"
    kubectl get deployment -A -o wide || true
    die "client deployment was created in the wrong namespace or was not created"
  fi

  kubectl rollout status deployment/server -n "${APP_NS}" --timeout=600s
  kubectl rollout status deployment/client -n "${APP_NS}" --timeout=600s
}

service_preflight() {
  msg "Checking client -> server Service path"
  if ! kubectl exec -n "${APP_NS}" deployment/client -c client -- \
    wget -q -T 5 -O - http://server:8080/health >/dev/null; then
    kubectl get pods -n "${APP_NS}" -o wide || true
    kubectl get svc,endpoints -n "${APP_NS}" || true
    die "Application Service preflight failed"
  fi
}

ambient_preflight() {
  service_preflight
  msg "Ambient components"
  kubectl get pods -n istio-system -o wide
}

http_status_from_client() {
  local method="$1"
  local url="$2"
  local output=""

  if [[ "${method}" == "POST" ]]; then
    output="$(kubectl exec -n "${APP_NS}" deployment/client -c client -- \
      wget -S -O - --post-data=probe "${url}" 2>&1 >/dev/null || true)"
  else
    output="$(kubectl exec -n "${APP_NS}" deployment/client -c client -- \
      wget -S -O - "${url}" 2>&1 >/dev/null || true)"
  fi

  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^HTTP\/[0-9.]+$/ && (i + 1) <= NF && $(i + 1) ~ /^[0-9][0-9][0-9]$/) {
        status = $(i + 1)
      }
    }
  } END { print status }' <<<"${output}"
}

ambient_l7_preflight() {
  ambient_preflight
  msg "Checking Ambient L7 policy through the waypoint"

  local timeout="${AMBIENT_L7_PREFLIGHT_TIMEOUT:-90}"
  local interval="${AMBIENT_L7_PREFLIGHT_INTERVAL:-2}"
  local end_ts=$((SECONDS + timeout))
  local attempt=0
  local get_status=""
  local post_status=""

  while (( SECONDS < end_ts )); do
    attempt=$((attempt + 1))
    get_status="$(http_status_from_client GET http://server:8080/api/data)"
    post_status="$(http_status_from_client POST http://server:8080/api/data)"

    if [[ "${get_status}" == "200" && "${post_status}" == "403" ]]; then
      msg "Ambient L7 policy is ready through the waypoint (attempt ${attempt})"
      return 0
    fi

    warn "Ambient L7 waypoint not ready yet (attempt ${attempt}): GET=${get_status:-no-status}, POST=${post_status:-no-status}; retrying in ${interval}s"
    sleep "${interval}"
  done

  warn "Ambient L7 preflight timed out after ${timeout}s"
  kubectl get gateway/server-waypoint -n "${APP_NS}" -o wide || true
  kubectl get pods -n "${APP_NS}" -o wide || true
  kubectl get pods -n istio-system -o wide || true
  kubectl get authorizationpolicy.security.istio.io -n "${APP_NS}" || true

  warn "Raw Ambient L7 GET probe output:"
  kubectl exec -n "${APP_NS}" deployment/client -c client -- \
    wget -S -O - http://server:8080/api/data 2>&1 >/dev/null || true
  warn "Raw Ambient L7 POST probe output:"
  kubectl exec -n "${APP_NS}" deployment/client -c client -- \
    wget -S -O - --post-data=probe http://server:8080/api/data 2>&1 >/dev/null || true

  die "Ambient L7 preflight failed after ${timeout}s: GET /api/data returned ${get_status:-no HTTP status} (expected 200), POST /api/data returned ${post_status:-no HTTP status} (expected 403)"
}

dikastes_preflight() {
  service_preflight
  local names=""
  names="$(kubectl get pod -n "${APP_NS}" -l app=server -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')"
  [[ "${names}" == *"dikastes"* ]] || die "Dikastes was not injected into server pod"
  [[ "${names}" == *"istio-proxy"* ]] || die "Istio proxy was not injected into server pod"
}

create_k6_configmap() {
  kubectl create configmap k6-scripts -n "${APP_NS}" \
    --from-file="${ROOT_DIR}/k6" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_metrics_api() {
  local timeout="${1:-90}"
  local end_ts=$((SECONDS + timeout))
  while (( SECONDS < end_ts )); do
    if kubectl top nodes --no-headers >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

assert_no_user_policies() {
  local bad=0
  if kubectl get networkpolicy.projectcalico.org -n "${APP_NS}" --no-headers 2>/dev/null | grep -q .; then
    warn "Calico NetworkPolicy exists in baseline namespace"
    kubectl get networkpolicy.projectcalico.org -n "${APP_NS}" || true
    bad=1
  fi
  if kubectl get authorizationpolicy.security.istio.io -n "${APP_NS}" --no-headers 2>/dev/null | grep -q .; then
    warn "Istio AuthorizationPolicy exists in baseline namespace"
    kubectl get authorizationpolicy.security.istio.io -n "${APP_NS}" || true
    bad=1
  fi
  (( bad == 0 )) || die "Baseline contains a user-defined policy"
}

print_ready_message() {
  local model="$1"
  local cluster_name="$2"
  echo
  msg "${model} is ready"
  echo "Context: k3d-${cluster_name}"
  echo "Namespace: ${APP_NS}"
  echo "App image: ${APP_IMAGE}"
}

wait_k6_pod_created() {
  local ns="$1"
  local job_name="$2"
  local pod=""
  for _ in $(seq 1 90); do
    pod="$(kubectl get pod -n "${ns}" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${pod}" ]] && { echo "${pod}"; return 0; }
    sleep 1
  done
  return 1
}

wait_pod_running_or_done() {
  local ns="$1"
  local pod="$2"
  local phase=""
  for _ in $(seq 1 180); do
    phase="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Running|Succeeded) return 0 ;;
      Failed) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

wait_for_pod_file() {
  local ns="$1"
  local pod="$2"
  local path="$3"
  local timeout="${4:-900}"
  local end_ts=$((SECONDS + timeout))
  while (( SECONDS < end_ts )); do
    if kubectl exec -n "${ns}" "${pod}" -c k6 -- sh -c "test -f '${path}'" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

copy_pod_file() {
  local ns="$1"
  local pod="$2"
  local remote="$3"
  local local_file="$4"
  if kubectl exec -n "${ns}" "${pod}" -c k6 -- sh -c "test -f '${remote}'" >/dev/null 2>&1; then
    kubectl exec -n "${ns}" "${pod}" -c k6 -- sh -c "cat '${remote}'" > "${local_file}"
    return 0
  fi
  return 1
}

render_k6_job() {
  local job_name="$1"
  local script_name="$2"
  local output="$3"

  sed \
    -e "s|__JOB_NAME__|${job_name}|g" \
    -e "s|__APP_NS__|${APP_NS}|g" \
    -e "s|__K6_SCRIPT__|${script_name}|g" \
    -e "s|__MODEL__|${K6_MODEL}|g" \
    -e "s|__VUS__|${VUS}|g" \
    -e "s|__DURATION__|${DURATION}|g" \
    -e "s|__TARGET_URL__|${TARGET_URL}|g" \
    -e "s|__TARGET_MODE__|${TARGET_MODE}|g" \
    -e "s|__RPS__|${RPS}|g" \
    -e "s|__PAYLOAD_SIZE__|${PAYLOAD_SIZE}|g" \
    -e "s|__RESPONSE_SIZE__|${RESPONSE_SIZE}|g" \
    -e "s|__REQUEST_METHOD__|${REQUEST_METHOD}|g" \
    -e "s|__REQUEST_PATH__|${REQUEST_PATH}|g" \
    -e "s|__TEST_MODE__|${TEST_MODE}|g" \
    -e "s|__NO_CONNECTION_REUSE__|${NO_CONNECTION_REUSE}|g" \
    -e "s|__SERVER_DELAY_MS__|${SERVER_DELAY_MS}|g" \
    -e "s|__TIMEOUT__|${TIMEOUT}|g" \
    -e "s|__SLEEP_MS__|${SLEEP_MS}|g" \
    -e "s|__ALLOWED_RPS__|${ALLOWED_RPS}|g" \
    -e "s|__BLOCKED_RPS__|${BLOCKED_RPS}|g" \
    -e "s|__BLOCKED_TARGET_URL__|${BLOCKED_TARGET_URL}|g" \
    -e "s|__BLOCKED_METHOD__|${BLOCKED_METHOD}|g" \
    -e "s|__BLOCKED_PATH__|${BLOCKED_PATH}|g" \
    -e "s|__SCENARIO_VARIANT__|${SCENARIO_VARIANT}|g" \
    "${ROOT_DIR}/k8s/k6-job.yaml.tmpl" > "${output}"
}
