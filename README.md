# Diploma Kubernetes traffic tests: Calico eBPF + Istio

This package replaces the old Linkerd-oriented scripts with a structure for three diploma models:

1. `baseline-calico-ebpf`
   - Kubernetes on k3d/k3s
   - Calico Open Source eBPF dataplane
   - Calico L3/L4 policy
   - client/server workload
   - Prometheus and Grafana

2. `istio-ambient-l4`
   - baseline
   - Istio Ambient mode
   - ztunnel only
   - no waypoint proxy

3. `istio-l7-dikastes`
   - baseline
   - Istio sidecar mode
   - Envoy proxy
   - Dikastes sidecar
   - Calico L7 HTTP policy

## Required tools

Install these tools on the host:

```bash
kubectl
k3d
docker
helm
istioctl
python3
jq
```

`jq` is needed only by `run-until-fail.sh`.

## Main commands

From the project root:

```bash
bash scripts/up.sh baseline
bash scripts/up.sh ambient-l4
bash scripts/up.sh l7-dikastes
```

Run k6:

```bash
bash scripts/run-k6.sh baseline loadtest.js
bash scripts/run-k6.sh ambient-l4 loadtest.js
bash scripts/run-k6.sh l7-dikastes loadtest.js
```

Run with custom parameters:

```bash
VUS=50 DURATION=60s PAYLOAD_SIZE=1024 RESPONSE_SIZE=1024 \
  bash scripts/run-k6.sh baseline loadtest.js
```

Test L7 blocking in Dikastes model:

```bash
TEST_MODE=mixed FAIL_RATE_THRESHOLD=1 SUCCESS_RATE_THRESHOLD=0.5 \
  bash scripts/run-k6.sh l7-dikastes loadtest.js
```

Stop cluster without deleting it:

```bash
bash scripts/down.sh baseline soft
```

Delete cluster:

```bash
bash scripts/down.sh baseline hard
```

Delete all clusters:

```bash
bash scripts/down.sh all hard
```

Show status:

```bash
bash scripts/status.sh baseline
bash scripts/status.sh ambient-l4
bash scripts/status.sh l7-dikastes
```

Generate plots and CSV:

```bash
python3 scripts/plot-results.py --results results --out results/plots
```

## Useful environment variables

Cluster variables:

```bash
K3D_IMAGE=rancher/k3s:v1.34.4-k3s1
K3D_SERVERS=1
K3D_AGENTS=1
CALICO_VERSION=v3.32.0
DIKASTES_VERSION=v3.32
ISTIO_VERSION=1.28.1
INSTALL_MONITORING=true
START_PORT_FORWARDS=true
APP_NS=test-app
```

k6 variables:

```bash
VUS=20
DURATION=30s
RPS=0
TARGET_URL=http://client:8080/proxy
TEST_MODE=allowed
REQUEST_METHOD=GET
REQUEST_PATH=/api/data
PAYLOAD_SIZE=128
RESPONSE_SIZE=128
SERVER_DELAY_MS=0
NO_CONNECTION_REUSE=false
TIMEOUT=5s
SLEEP_MS=100
FAIL_RATE_THRESHOLD=0.05
P95_THRESHOLD_MS=1000
SUCCESS_RATE_THRESHOLD=0.95
```

## Test modes

`TEST_MODE=allowed`

Normal performance test. It sends allowed traffic and expects HTTP 200.

`TEST_MODE=blocked`

Sends `POST /api/data`. In the L7 Dikastes model this should return 403.

`TEST_MODE=admin-blocked`

Sends `GET /admin`. In the L7 Dikastes model this should return 403.

`TEST_MODE=mixed`

Mixes allowed and blocked requests. This is useful to verify L7 policy behavior, but k6 `http_req_failed` will increase because 403 is still a failed HTTP request from k6 point of view.

## Grafana and Prometheus

By default the scripts install kube-prometheus-stack through Helm and start port-forwards:

```text
Grafana:    http://localhost:3000
Prometheus: http://localhost:9090
Grafana login: admin
Grafana password: admin
```

Change the password:

```bash
GRAFANA_ADMIN_PASSWORD=my-password bash scripts/up.sh baseline
```

## Notes

- Calico Enterprise is not used.
- Calico eBPF replaces kube-proxy, so the k3d cluster is created with `--disable-kube-proxy`.
- k3s flannel and the built-in k3s network policy controller are disabled.
- For the L7 Dikastes model, Calico `bpfConnectTimeLoadBalancing` is set to `Disabled` because Calico documentation warns about this setting when using Dikastes.
- The app is intentionally simple and uses Python standard library only. This reduces application noise in measurements.
# Dyploma
