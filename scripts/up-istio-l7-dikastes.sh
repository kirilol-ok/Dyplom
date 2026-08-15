#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
CLUSTER_NAME=istio-l7-dikastes
check_base_tools
check_istio_tools
create_cluster "$CLUSTER_NAME"
use_cluster "$CLUSTER_NAME"
install_calico_ebpf "$CLUSTER_NAME"
install_istio_dikastes
label_namespace "$APP_NS" istio-injection=enabled
apply_app "$APP_NS" dikastes
apply_l7_policy "$APP_NS"
create_k6_configmap "$APP_NS"
wait_app_ready "$APP_NS"
print_ready_message "$CLUSTER_NAME" istio-l7-dikastes
