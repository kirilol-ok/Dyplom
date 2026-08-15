#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
MODEL="${1:-baseline}"
CLUSTER="$(model_cluster "$MODEL")"
use_cluster "$CLUSTER"
echo "== Nodes =="
kubectl get nodes -L benchmark-role -o wide
echo
echo "== Workloads =="
kubectl get pods -n "$APP_NS" -o wide
echo
echo "== Server resources =="
kubectl get deployment server -n "$APP_NS" -o jsonpath='{.spec.template.spec.containers[?(@.name=="server")].resources}{"\n"}'
echo
echo "== Server Service and EndpointSlice =="
kubectl get svc server -n "$APP_NS" -o wide
kubectl get endpointslice -n "$APP_NS" -l kubernetes.io/service-name=server -o wide
echo
echo "== Calico benchmark policies =="
kubectl get networkpolicies.projectcalico.org -n "$APP_NS" -o wide || true
echo
echo "== Calico installation =="
kubectl get installation.operator.tigera.io default -o jsonpath='dataplane={.spec.calicoNetwork.linuxDataplane} bgp={.spec.calicoNetwork.bgp} encapsulation={.spec.calicoNetwork.ipPools[0].encapsulation}{"\n"}'
kubectl get felixconfiguration default -o jsonpath='bpfConnectTimeLoadBalancing={.spec.bpfConnectTimeLoadBalancing} policySyncPathPrefix={.spec.policySyncPathPrefix}{"\n"}'
echo
echo "== Tigera status =="
kubectl get tigerastatus
if [[ "$(model_short "$MODEL")" == l7-dikastes ]]; then
  echo
  echo "== Istio/Dikastes containers =="
  kubectl get pods -n "$APP_NS" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.initContainers[*].name}{" | "}{.spec.containers[*].name}{"\n"}{end}'
fi
