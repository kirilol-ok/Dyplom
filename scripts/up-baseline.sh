#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
CLUSTER_NAME=baseline-calico-ebpf
check_base_tools
create_cluster "$CLUSTER_NAME"
use_cluster "$CLUSTER_NAME"
install_calico_ebpf "$CLUSTER_NAME"
set_bpf_ctlb TCP
ensure_namespace "$APP_NS"
apply_app "$APP_NS" normal
apply_l4_policy "$APP_NS"
create_k6_configmap "$APP_NS"
wait_app_ready "$APP_NS"
print_ready_message "$CLUSTER_NAME" baseline-calico-ebpf
