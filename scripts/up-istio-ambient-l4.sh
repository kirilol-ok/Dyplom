#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CLUSTER_NAME=istio-ambient-l4

check_base_tools
check_istio_tools
create_cluster "$CLUSTER_NAME"
use_cluster "$CLUSTER_NAME"
install_calico_ebpf "$CLUSTER_NAME"
install_istio_ambient_l4
label_namespace "$APP_NS" istio.io/dataplane-mode=ambient
apply_app "$APP_NS" normal

# Istio Ambient rewrites kubelet health probes to use the link-local
# source address 169.254.7.127. Allow these probes before applying the
# restrictive L4 policy, otherwise the server can enter CrashLoopBackOff.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed "s|__APP_NS__|${APP_NS}|g"   "${PROJECT_ROOT}/k8s/policies/calico-ambient-health-probes.yaml"   | kubectl apply -f -

apply_l4_policy "$APP_NS"
create_k6_configmap "$APP_NS"
wait_app_ready "$APP_NS"

# Tigerastatus/Pod Ready alone is not enough for Ambient. Verify that an
# HBONE workload on the load-generator node can actually reach the server
# through the Kubernetes Service before declaring the model ready.
ambient_dataplane_preflight "$APP_NS"

msg "Ambient components"
kubectl get pods -n calico-system -o wide \
  | awk 'NR == 1 || $1 ~ /^(istiod|ztunnel|istio-cni-node)-/'
print_ready_message "$CLUSTER_NAME" istio-ambient-l4
