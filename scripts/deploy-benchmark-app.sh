#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ $# -eq 1 ]] || { echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"; exit 1; }
MODEL="$(model_short "$1")"
CLUSTER="$(model_cluster "$MODEL")"
use_cluster "$CLUSTER"
case "$MODEL" in
  l7-dikastes) apply_app "$APP_NS" dikastes; apply_l7_policy "$APP_NS" ;;
  *) apply_app "$APP_NS" normal; apply_l4_policy "$APP_NS" ;;
esac
create_k6_configmap "$APP_NS"
wait_app_ready "$APP_NS"
