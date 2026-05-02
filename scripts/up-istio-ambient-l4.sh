#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CLUSTER_NAME="istio-ambient-l4"
APP_NS="${APP_NS:-test-app}"

check_base_tools
check_istio_tools
create_cluster "${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"

install_calico_ebpf "TCP"
install_istio_ambient_l4
label_namespace "${APP_NS}" istio.io/dataplane-mode=ambient
apply_app "${APP_NS}" "normal"
apply_l4_policy "${APP_NS}"
create_k6_configmap "${APP_NS}"

install_monitoring
wait_pods_ready "${APP_NS}" 600s
start_monitoring_port_forwards "${CLUSTER_NAME}"
verify_calico_ebpf
print_ready_message "${CLUSTER_NAME}" "istio-ambient-l4"
