#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODEL=calico-l7
CLUSTER_NAME="$(model_cluster "${MODEL}")"

check_base_tools
check_istio_tools
create_cluster "${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"
install_calico_ebpf "${CLUSTER_NAME}"
install_istio_dikastes
build_and_import_app_image "${CLUSTER_NAME}"
reset_app_namespace
label_namespace "${APP_NS}" istio-injection=enabled
apply_app dikastes
apply_calico_l7_policy
create_k6_configmap
wait_app_ready
dikastes_preflight
print_ready_message "${MODEL}" "${CLUSTER_NAME}"
