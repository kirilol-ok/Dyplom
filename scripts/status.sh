#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 <model>"; exit 1; }
MODEL="$(canonical_model "$1")"
CLUSTER_NAME="$(model_cluster "${MODEL}")"

cluster_exists "${CLUSTER_NAME}" || die "Cluster does not exist: ${CLUSTER_NAME}"
use_cluster "${CLUSTER_NAME}"

echo "Model:   ${MODEL}"
echo "Cluster: ${CLUSTER_NAME}"
echo

echo "== Nodes =="
kubectl get nodes -o wide

echo
echo "== Application =="
kubectl get pods,svc -n "${APP_NS}" -o wide || true

echo
echo "== Calico policies in ${APP_NS} =="
kubectl get networkpolicy.projectcalico.org -n "${APP_NS}" 2>/dev/null || echo "No Calico policy resources"

echo
echo "== Kubernetes NetworkPolicy in ${APP_NS} =="
kubectl get networkpolicy.networking.k8s.io -n "${APP_NS}" 2>/dev/null || echo "No Kubernetes NetworkPolicy resources"

echo
echo "== Istio AuthorizationPolicy in ${APP_NS} =="
kubectl get authorizationpolicy.security.istio.io -n "${APP_NS}" 2>/dev/null || echo "No Istio AuthorizationPolicy resources"

echo
echo "== Waypoints / Gateway API =="
kubectl get gateway.gateway.networking.k8s.io -n "${APP_NS}" 2>/dev/null || echo "No waypoint Gateway resources"

echo
echo "== Calico components =="
kubectl get pods -n calico-system -o wide 2>/dev/null || true

echo
echo "== Istio components =="
kubectl get pods -n istio-system -o wide 2>/dev/null || echo "Istio is not installed in this model"

echo
echo "== Namespace labels =="
kubectl get namespace "${APP_NS}" --show-labels

echo
echo "== Felix settings relevant to the experiment =="
kubectl get felixconfiguration default \
  -o jsonpath='bpfConnectTimeLoadBalancing={.spec.bpfConnectTimeLoadBalancing} policySyncPathPrefix={.spec.policySyncPathPrefix}{"\n"}' \
  2>/dev/null || true
