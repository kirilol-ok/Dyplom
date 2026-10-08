#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODEL=ambient-l7
CLUSTER_NAME="$(model_cluster "${MODEL}")"

check_base_tools
check_istio_tools
create_cluster "${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"
install_calico_ebpf "${CLUSTER_NAME}"
install_gateway_api_crds
install_istio_ambient
build_and_import_app_image "${CLUSTER_NAME}"
reset_app_namespace
create_waypoint_for_server
label_namespace "${APP_NS}" istio.io/dataplane-mode=ambient
apply_app normal
wait_app_ready
apply_ambient_l7_policy
create_k6_configmap
ambient_l7_preflight
print_ready_message "${MODEL}" "${CLUSTER_NAME}"
