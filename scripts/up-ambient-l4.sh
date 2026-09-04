#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODEL=ambient-l4
CLUSTER_NAME="$(model_cluster "${MODEL}")"

check_base_tools
check_istio_tools
create_cluster "${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"
install_calico_ebpf "${CLUSTER_NAME}"
install_istio_ambient
build_and_import_app_image "${CLUSTER_NAME}"
reset_app_namespace
label_namespace "${APP_NS}" istio.io/dataplane-mode=ambient
apply_app normal
apply_ambient_l4_policy
create_k6_configmap
wait_app_ready
ambient_preflight
print_ready_message "${MODEL}" "${CLUSTER_NAME}"
