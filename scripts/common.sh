#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp"
RESULTS_DIR="${ROOT_DIR}/results"
mkdir -p "${TMP_DIR}" "${RESULTS_DIR}"

K3D_IMAGE="${K3D_IMAGE:-rancher/k3s:v1.34.4-k3s1}"
K3D_SERVERS="${K3D_SERVERS:-1}"
K3D_AGENTS="${K3D_AGENTS:-2}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
APP_NS="${APP_NS:-test-app}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
DIKASTES_VERSION="${DIKASTES_VERSION:-v3.32.1}"
BENCHMARK_APP_REPOSITORY="${BENCHMARK_APP_REPOSITORY:-diploma-benchmark-app}"
BENCHMARK_APP_CONTEXT="${BENCHMARK_APP_CONTEXT:-${ROOT_DIR}/apps/benchmark-app}"
BENCHMARK_APP_IMAGE="${BENCHMARK_APP_IMAGE:-}"
BUILD_BENCHMARK_APP="${BUILD_BENCHMARK_APP:-true}"

msg() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

require_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
check_base_tools() { require_bin kubectl; require_bin k3d; require_bin docker; require_bin sed; require_bin awk; }
check_istio_tools() { require_bin istioctl; }
check_result_tools() { require_bin python3; }

ready_pod_by_label() {
  local ns="$1"
  local selector="$2"

  kubectl get pods -n "$ns" -l "$selector" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    2>/dev/null \
    | awk -F'|' '$2 == "" && $3 == "True" {print $1; exit}'
}

model_cluster() {
  case "$1" in
    baseline|baseline-calico-ebpf) echo baseline-calico-ebpf ;;
    ambient-l4|istio-ambient-l4|l4) echo istio-ambient-l4 ;;
    l7|l7-dikastes|istio-l7-dikastes) echo istio-l7-dikastes ;;
    *) die "Unknown model: $1" ;;
  esac
}

model_short() {
  case "$1" in
    baseline|baseline-calico-ebpf) echo baseline ;;
    ambient-l4|istio-ambient-l4|l4) echo ambient-l4 ;;
    l7|l7-dikastes|istio-l7-dikastes) echo l7-dikastes ;;
    *) die "Unknown model: $1" ;;
  esac
}

cluster_exists() {
  local name="$1"
  k3d cluster list --no-headers 2>/dev/null | awk -v n="$name" '$1 == n {found=1} END {exit !found}'
}

use_cluster() {
  local name="$1"
  local lb="k3d-${name}-serverlb"
  local port=""
  local kube_cluster=""
  kubectl config use-context "k3d-${name}" >/dev/null
  if docker ps -a --format '{{.Names}}' | grep -qx "$lb"; then
    port="$(docker port "$lb" 6443/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
    kube_cluster="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
    if [[ -n "$port" && -n "$kube_cluster" ]]; then
      kubectl config set-cluster "$kube_cluster" --server="https://127.0.0.1:${port}" >/dev/null
    fi
  fi
}

wait_resource_exists() {
  local resource="$1"
  local ns="${2:-}"
  local timeout="${3:-300}"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if [[ -n "$ns" ]]; then
      kubectl get "$resource" -n "$ns" >/dev/null 2>&1 && return 0
    else
      kubectl get "$resource" >/dev/null 2>&1 && return 0
    fi
    sleep 2
  done
  die "Timed out waiting for ${resource}${ns:+ in ${ns}}"
}

wait_namespace_exists() {
  local ns="$1"
  local timeout="${2:-300}"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    kubectl get ns "$ns" >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Timed out waiting for namespace ${ns}"
}

configure_benchmark_nodes() {
  local cluster="$1"
  local cp="k3d-${cluster}-server-0"
  local app="k3d-${cluster}-agent-0"
  local load="k3d-${cluster}-agent-1"

  for node in "$cp" "$app" "$load"; do
    kubectl get node "$node" >/dev/null 2>&1 || die "Required node is missing: ${node}"
  done

  kubectl label node "$cp" benchmark-role=control-plane --overwrite >/dev/null
  kubectl label node "$app" benchmark-role=application --overwrite >/dev/null
  kubectl label node "$load" benchmark-role=load-generator --overwrite >/dev/null
  kubectl taint node "$load" dedicated=load-generator:NoSchedule --overwrite >/dev/null
  kubectl get nodes -L benchmark-role -o wide
}

create_cluster() {
  local name="$1"
  if cluster_exists "$name"; then
    msg "Cluster already exists: ${name}; starting/reusing it"
    k3d cluster start "$name" >/dev/null 2>&1 || true
    use_cluster "$name"
    # Nodes may legitimately be NotReady before Calico is installed.
    # Do not wait for Ready here; install_calico_ebpf() performs the real readiness wait.
    configure_benchmark_nodes "$name"
    return
  fi

  msg "Creating ${name}"
  k3d cluster create "$name" \
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
  use_cluster "$name"
  configure_benchmark_nodes "$name"
}

ensure_namespace() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

label_namespace() {
  local ns="$1"; shift
  ensure_namespace "$ns"
  kubectl label namespace "$ns" "$@" --overwrite >/dev/null
}

benchmark_app_source_tag() {
  local files=("${BENCHMARK_APP_CONTEXT}/go.mod" "${BENCHMARK_APP_CONTEXT}/main.go" "${BENCHMARK_APP_CONTEXT}/Dockerfile")
  if command -v sha256sum >/dev/null 2>&1; then
    cat "${files[@]}" | sha256sum | awk '{print substr($1,1,12)}'
  else
    cat "${files[@]}" | shasum -a 256 | awk '{print substr($1,1,12)}'
  fi
}

resolve_benchmark_app_image() {
  [[ -n "$BENCHMARK_APP_IMAGE" ]] || BENCHMARK_APP_IMAGE="${BENCHMARK_APP_REPOSITORY}:$(benchmark_app_source_tag)"
  export BENCHMARK_APP_IMAGE
}

build_and_import_benchmark_app() {
  local cluster="$1"
  resolve_benchmark_app_image
  if [[ "$BUILD_BENCHMARK_APP" == true ]]; then
    msg "Building ${BENCHMARK_APP_IMAGE}"
    docker build -t "$BENCHMARK_APP_IMAGE" "$BENCHMARK_APP_CONTEXT"
  else
    docker image inspect "$BENCHMARK_APP_IMAGE" >/dev/null 2>&1 || die "Local image not found: ${BENCHMARK_APP_IMAGE}"
  fi
  k3d image import --cluster "$cluster" "$BENCHMARK_APP_IMAGE"
}

render_app_manifest() {
  sed "s|__BENCHMARK_APP_IMAGE__|${BENCHMARK_APP_IMAGE}|g" "$1"
}

configure_tigera_direct_api_access() {
  local cluster="$1"
  local server="k3d-${cluster}-server-0"
  local network="k3d-${cluster}"
  local api_ip=""
  api_ip="$(docker inspect --format "{{with index .NetworkSettings.Networks \"${network}\"}}{{.IPAddress}}{{end}}" "$server")"
  [[ -n "$api_ip" ]] || die "Cannot determine direct API IP for ${cluster}"

  ensure_namespace tigera-operator
  kubectl -n tigera-operator create configmap kubernetes-services-endpoint \
    --from-literal=KUBERNETES_SERVICE_HOST="$api_ip" \
    --from-literal=KUBERNETES_SERVICE_PORT=6443 \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  msg "Calico direct API endpoint: ${api_ip}:6443"
}

install_calico_ebpf() {
  local cluster="$1"
  local rendered="${TMP_DIR}/calico-installation.yaml"
  use_cluster "$cluster"

  msg "Installing Calico ${CALICO_VERSION} CRDs"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v1_crd_projectcalico_org.yaml"

  configure_tigera_direct_api_access "$cluster"

  msg "Installing Tigera Operator"
  kubectl apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
  wait_resource_exists deployment/tigera-operator tigera-operator 300
  kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=300s

  sed "s|__POD_CIDR__|${POD_CIDR}|g" "${ROOT_DIR}/k8s/calico/installation.yaml.tmpl" > "$rendered"
  msg "Applying minimal Calico eBPF installation (VXLAN always, BGP disabled)"
  kubectl apply -f "$rendered"

  wait_namespace_exists calico-system 300
  wait_resource_exists daemonset/calico-node calico-system 300
  wait_resource_exists deployment/calico-kube-controllers calico-system 300
  kubectl rollout status daemonset/calico-node -n calico-system --timeout=600s
  kubectl rollout status deployment/calico-kube-controllers -n calico-system --timeout=600s
  kubectl wait --for=condition=Ready nodes --all --timeout=600s

  wait_resource_exists tigerastatus/calico "" 300
  wait_resource_exists tigerastatus/apiserver "" 300
  kubectl wait --for=condition=Available tigerastatus/calico --timeout=600s
  kubectl wait --for=condition=Available tigerastatus/apiserver --timeout=600s

  if kubectl get daemonset kube-proxy -n kube-system >/dev/null 2>&1; then
    die "kube-proxy is present although the benchmark cluster is configured for Calico eBPF replacement"
  fi

  msg "Calico is ready"
  kubectl get installation.operator.tigera.io default \
    -o jsonpath='dataplane={.spec.calicoNetwork.linuxDataplane} bgp={.spec.calicoNetwork.bgp} encapsulation={.spec.calicoNetwork.ipPools[0].encapsulation}{"\n"}'
}

set_bpf_ctlb() {
  local mode="$1"
  kubectl patch felixconfiguration default --type merge \
    -p "{\"spec\":{\"bpfConnectTimeLoadBalancing\":\"${mode}\"}}" >/dev/null
  msg "bpfConnectTimeLoadBalancing=${mode}"
}

wait_ambient_workload_hbone() {
  local ns="$1"
  local pod="$2"
  local timeout="${3:-180}"
  local end=$((SECONDS + timeout))

  while (( SECONDS < end )); do
    if istioctl ztunnel-config workloads -n calico-system 2>/dev/null       | awk -v ns="$ns" -v pod="$pod" '$1 == ns && $2 == pod && $NF == "HBONE" {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_ambient_service_ready() {
  local ns="$1"
  local service="$2"
  local timeout="${3:-180}"
  local end=$((SECONDS + timeout))

  while (( SECONDS < end )); do
    if istioctl ztunnel-config services -n calico-system --service-namespace "$ns" 2>/dev/null       | awk -v service="$service" '$2 == service && $NF ~ /^[1-9][0-9]*\/[1-9][0-9]*$/ {split($NF,a,"/"); if (a[1] == a[2]) found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_ambient_felix_ready() {
  local timeout="${1:-180}"
  local end=$((SECONDS + timeout))
  local ctlb=""
  local ambient=""

  while (( SECONDS < end )); do
    ctlb="$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfConnectTimeLoadBalancing}' 2>/dev/null || true)"
    ambient="$(kubectl get felixconfiguration default -o jsonpath='{.spec.istioAmbientMode}' 2>/dev/null || true)"
    if [[ "$ctlb" == Disabled && "$ambient" == Enabled ]]; then
      return 0
    fi
    sleep 2
  done

  warn "Felix Ambient state did not converge: bpfConnectTimeLoadBalancing=${ctlb:-<empty>} istioAmbientMode=${ambient:-<empty>}"
  return 1
}

wait_ambient_components_ready() {
  wait_namespace_exists calico-system 300
  wait_resource_exists daemonset/ztunnel calico-system 300
  wait_resource_exists daemonset/istio-cni-node calico-system 300
  wait_resource_exists deployment/istiod calico-system 300
  kubectl rollout status daemonset/ztunnel -n calico-system --timeout=600s
  kubectl rollout status daemonset/istio-cni-node -n calico-system --timeout=600s
  kubectl rollout status deployment/istiod -n calico-system --timeout=600s
  wait_ambient_felix_ready 180 || die "Calico/Istio Ambient Felix integration is not ready"
}

ambient_dataplane_preflight() {
  local ns="$1"
  local probe="ambient-preflight"
  local target="http://server:8080/health"
  local end=0
  local consecutive=0

  check_istio_tools
  msg "Running Ambient dataplane preflight"
  kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${probe}
  namespace: ${ns}
  labels:
    app: k6
    benchmark-role: load-generator
spec:
  serviceAccountName: benchmark-client
  nodeSelector:
    benchmark-role: load-generator
  tolerations:
    - key: dedicated
      operator: Equal
      value: load-generator
      effect: NoSchedule
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.36
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: 10m
          memory: 8Mi
        limits:
          cpu: 100m
          memory: 32Mi
YAML

  if ! kubectl wait --for=condition=Ready "pod/${probe}" -n "$ns" --timeout=180s >/dev/null; then
    kubectl describe pod "$probe" -n "$ns" >&2 || true
    kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    die "Ambient preflight pod did not become Ready"
  fi

  if ! wait_ambient_workload_hbone "$ns" "$probe" 180; then
    istioctl ztunnel-config workloads -n calico-system >&2 || true
    kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    die "Ambient preflight pod was not enrolled as HBONE"
  fi

  if ! wait_ambient_service_ready "$ns" server 180; then
    istioctl ztunnel-config services -n calico-system --service-namespace "$ns" >&2 || true
    kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    die "Ambient ztunnel service discovery is not ready for service/server"
  fi

  # Require five consecutive successful Service requests from an actual HBONE
  # source on the load-generator node. This catches the transient enrollment /
  # Service-VIP state that a simple Pod Ready or Tigerastatus check misses.
  end=$((SECONDS + 120))
  while (( SECONDS < end )); do
    if kubectl exec -n "$ns" "$probe" -c probe --       wget -q -T 3 -O /dev/null "$target" >/dev/null 2>&1; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= 5 )); then
        kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
        msg "Ambient dataplane preflight passed (HBONE + Service VIP + 5/5 HTTP checks)"
        return 0
      fi
      sleep 1
    else
      consecutive=0
      sleep 2
    fi
  done

  warn "Ambient dataplane preflight failed; dumping ztunnel state"
  istioctl ztunnel-config workloads -n calico-system >&2 || true
  istioctl ztunnel-config services -n calico-system --service-namespace "$ns" >&2 || true
  kubectl logs -n calico-system -l app.kubernetes.io/name=ztunnel --since=2m --prefix >&2 || true
  kubectl delete pod "$probe" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  die "Ambient dataplane is not functionally ready"
}

install_istio_ambient_l4() {
  msg "Installing Calico-managed Istio Ambient"
  set_bpf_ctlb Disabled
  kubectl apply -f - <<'YAML'
apiVersion: operator.tigera.io/v1
kind: Istio
metadata:
  name: default
YAML
  wait_resource_exists tigerastatus/istio "" 300
  kubectl wait --for=condition=Available tigerastatus/istio --timeout=600s
  wait_ambient_components_ready
}

install_istio_dikastes() {
  check_istio_tools
  msg "Configuring Calico policy sync for Dikastes"
  set_bpf_ctlb Disabled
  kubectl patch felixconfiguration default --type merge -p '{"spec":{"policySyncPathPrefix":"/var/run/nodeagent"}}' >/dev/null
  kubectl patch installation.operator.tigera.io default --type merge -p '{"spec":{"flexVolumePath":"None"}}' >/dev/null || true

  local rendered="${TMP_DIR}/istio-operator-dikastes.yaml"
  sed "s|__DIKASTES_VERSION__|${DIKASTES_VERSION}|g" \
    "${ROOT_DIR}/k8s/istio/istio-operator-dikastes.yaml.tmpl" > "$rendered"
  istioctl install -f "$rendered" -y
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/alp/istio-app-layer-policy-envoy-v3.yaml"
  kubectl wait --for=condition=Ready pod --all -n istio-system --timeout=600s
}

apply_app() {
  local ns="$1"
  local mode="${2:-normal}"
  local cluster=""
  cluster="$(kubectl config current-context | sed 's/^k3d-//')"
  build_and_import_benchmark_app "$cluster"
  ensure_namespace "$ns"

  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/serviceaccounts.yaml"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/app/server-service.yaml"
  if [[ "$mode" == dikastes ]]; then
    render_app_manifest "${ROOT_DIR}/k8s/app/server-deployment-dikastes.yaml" | kubectl apply -n "$ns" -f -
  else
    render_app_manifest "${ROOT_DIR}/k8s/app/server-deployment.yaml" | kubectl apply -n "$ns" -f -
  fi

  kubectl rollout status deployment/server -n "$ns" --timeout=300s
}

clear_benchmark_policies() {
  local ns="$1"
  kubectl delete networkpolicy.projectcalico.org server-l4-allow-k6 -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete networkpolicy.projectcalico.org server-l7-http -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
}

apply_l4_policy() {
  local ns="$1"
  clear_benchmark_policies "$ns"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/policies/calico-l4-k6-to-server.yaml"
}

apply_l7_policy() {
  local ns="$1"
  clear_benchmark_policies "$ns"
  kubectl apply -n "$ns" -f "${ROOT_DIR}/k8s/policies/calico-l7-server-http-policy.yaml"
}

create_k6_configmap() {
  local ns="$1"
  kubectl create configmap k6-scripts -n "$ns" \
    --from-file="${ROOT_DIR}/k6" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_app_ready() {
  local ns="$1"
  kubectl wait --for=condition=Available deployment/server -n "$ns" --timeout=300s
}

print_ready_message() {
  local cluster="$1"
  local model="$2"
  echo
  msg "${model} is ready"
  echo "Context: k3d-${cluster}"
  echo "Namespace: ${APP_NS}"
  case "$model" in
    istio-ambient-l4)
      echo "Benchmark path: k6 (agent-1) -> source ztunnel -> HBONE/mTLS -> destination ztunnel -> server Service/Go server (agent-0)"
      ;;
    *)
      echo "Benchmark path: k6 (agent-1) -> server Service -> Go server (agent-0)"
      ;;
  esac
}

stop_cluster() {
  local name="$1"
  cluster_exists "$name" && k3d cluster stop "$name" || warn "Cluster does not exist: ${name}"
}

delete_cluster() {
  local name="$1"
  cluster_exists "$name" && k3d cluster delete "$name" || warn "Cluster does not exist: ${name}"
}
