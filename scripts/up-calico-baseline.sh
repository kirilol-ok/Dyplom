#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODEL=calico-baseline
CLUSTER_NAME="$(model_cluster "${MODEL}")"

check_base_tools
create_cluster "${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"
install_calico_ebpf "${CLUSTER_NAME}"
build_and_import_app_image "${CLUSTER_NAME}"
reset_app_namespace
apply_app normal
create_k6_configmap
wait_app_ready
service_preflight
assert_no_user_policies
print_ready_message "${MODEL}" "${CLUSTER_NAME}"
