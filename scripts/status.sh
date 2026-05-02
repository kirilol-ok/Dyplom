#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <baseline|ambient-l4|l7-dikastes>"
  exit 1
fi

MODEL="$1"
CLUSTER_NAME="$(model_cluster "${MODEL}")"
APP_NS="${APP_NS:-test-app}"

use_cluster "${CLUSTER_NAME}"

echo
echo "== Cluster =="
kubectl get nodes -o wide || true

echo
echo "== Namespaces =="
kubectl get ns "${APP_NS}" "${MONITORING_NS}" istio-system calico-system 2>/dev/null || true

echo
echo "== Calico =="
kubectl get tigerastatus 2>/dev/null || true
kubectl get installation.operator.tigera.io default -o jsonpath='linuxDataplane={.spec.calicoNetwork.linuxDataplane}{"\n"}' 2>/dev/null || true
kubectl get felixconfiguration default -o yaml 2>/dev/null | grep -E 'bpf|BPF|policySyncPathPrefix' || true

echo
echo "== Istio =="
kubectl get pods -n istio-system -o wide 2>/dev/null || true
kubectl get ns "${APP_NS}" --show-labels 2>/dev/null || true

echo
echo "== App =="
kubectl get pods,svc -n "${APP_NS}" -o wide 2>/dev/null || true

echo
echo "== Container names =="
kubectl get pods -n "${APP_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null || true

echo
echo "== Policies =="
kubectl get networkpolicy -A 2>/dev/null || true
kubectl get globalnetworkpolicy 2>/dev/null || true

echo
echo "== Useful checks =="
echo "Run k6: bash scripts/run-k6.sh ${MODEL} loadtest.js"
echo "Grafana: http://localhost:3000"
echo "Prometheus: http://localhost:9090"
