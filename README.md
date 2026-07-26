# Kubernetes Network and Service Mesh Benchmarking

Diploma project for comparing the performance, resource usage, and security capabilities of three Kubernetes networking models built with Calico eBPF and Istio.

The project creates reproducible k3d/k3s clusters, deploys the same client-server workload in each model, applies model-specific network policies, runs k6 benchmarks inside Kubernetes, and collects results for later comparison.

## Project Goals

The project evaluates three main questions:

1. **Functional capability** - which L3, L4, and L7 traffic policies are available in each model.
2. **Performance cost** - how latency, throughput, errors, CPU usage, and memory usage change when service mesh components are introduced.
3. **Scaling behavior** - how each architecture behaves when request rate, connection churn, payload size, and the number of workload replicas increase.

## Compared Cluster Models

| Model argument | Architecture | Traffic policy level | Main components |
|---|---|---|---|
| `baseline` | Calico eBPF without Istio | L3/L4 | Calico Open Source, eBPF dataplane, client and server workloads |
| `ambient-l4` | Istio Ambient without waypoint proxies | L4 | Baseline components, Istio control plane, node-level `ztunnel` |
| `l7-dikastes` | Istio sidecar mode integrated with Calico L7 policy | L3/L4/L7 | Baseline components, Envoy sidecar, Dikastes sidecar, Calico HTTP policy |

### Baseline: Calico eBPF

The baseline model uses Kubernetes on k3d/k3s with the Calico Open Source eBPF dataplane. Calico replaces kube-proxy and provides Kubernetes networking together with L3/L4 policy enforcement.

### Istio Ambient L4

The Ambient model extends the baseline with Istio Ambient mode. Traffic passes through a node-level `ztunnel`, which provides service mesh transport and L4 authorization capabilities. No waypoint proxy is deployed, so HTTP method and path rules are not evaluated by this model.

### Istio L7 with Dikastes

The L7 model uses Istio sidecar mode with Envoy and Dikastes next to the workload. This allows Calico policy enforcement based on HTTP properties such as request method and path.

## Repository Structure

The most relevant directories are expected to follow this layout:

```text
.
├── k6/
│   ├── loadtest.js
│   ├── benchmark-common.js
│   ├── policy-test.js
│   ├── steady-rps.js
│   ├── saturation.js
│   ├── connection-churn.js
│   └── concurrency-vus.js
├── k8s/
│   └── k6/
│       └── k6-job.yaml
├── scripts/
│   ├── common.sh
│   ├── up.sh
│   ├── down.sh
│   ├── status.sh
│   ├── run-k6.sh
│   ├── run-until-fail.sh
│   ├── run-benchmark-suite.sh
│   ├── run-rps-until-fail.sh
│   ├── collect-k8s-resources.sh
│   ├── run-resource-scaling.sh
│   ├── run-payload-matrix.sh
│   ├── run-topology-test.sh
│   ├── summarize-results.py
│   └── plot-results.py
└── results/
```

The exact repository may contain additional manifests and helper scripts.

## Requirements

Install the following tools on the host:

```text
Docker
kubectl
k3d
Helm
istioctl
Python 3
jq
```

The host does not need a local k6 installation because the tests are executed through a Kubernetes Job.

`jq` is required by the scripts that inspect k6 JSON summaries, including `run-until-fail.sh` and `run-rps-until-fail.sh`.

Git Bash or WSL is recommended on Windows.

## Quick Start

Run all commands from the repository root.

### 1. Create a cluster

```bash
bash scripts/up.sh baseline
```

Available models:

```bash
bash scripts/up.sh baseline
bash scripts/up.sh ambient-l4
bash scripts/up.sh l7-dikastes
```

Each model uses its own k3d cluster and kubeconfig context.

### 2. Check cluster status

```bash
bash scripts/status.sh baseline
bash scripts/status.sh ambient-l4
bash scripts/status.sh l7-dikastes
```

### 3. Run a basic k6 test

```bash
bash scripts/run-k6.sh baseline loadtest.js
```

Run the same workload against the other models:

```bash
bash scripts/run-k6.sh ambient-l4 loadtest.js
bash scripts/run-k6.sh l7-dikastes loadtest.js
```

Example with custom parameters:

```bash
VUS=50 \
DURATION=60s \
PAYLOAD_SIZE=1024 \
RESPONSE_SIZE=1024 \
  bash scripts/run-k6.sh baseline loadtest.js
```

### 4. Stop or remove clusters

Stop a cluster without deleting it:

```bash
bash scripts/down.sh baseline soft
```

Delete one cluster:

```bash
bash scripts/down.sh baseline hard
```

Delete all project clusters:

```bash
bash scripts/down.sh all hard
```

## Monitoring

By default, the project can install `kube-prometheus-stack` through Helm and start local port forwarding.

```text
Grafana:    http://localhost:3000
Prometheus: http://localhost:9090
Username:   admin
Password:   admin
```

Set a different Grafana password during cluster creation:

```bash
GRAFANA_ADMIN_PASSWORD=my-password \
  bash scripts/up.sh baseline
```

Monitoring behavior can be controlled with:

```bash
INSTALL_MONITORING=true
START_PORT_FORWARDS=true
```

The resource benchmark scripts use `kubectl top`. Verify that the Kubernetes Metrics API is available before running them:

```bash
kubectl top nodes
kubectl top pods -A
```

## Benchmark Suite

The benchmark suite reuses the existing `scripts/common.sh`, `scripts/run-k6.sh`, and `k8s/k6/k6-job.yaml` workflow. The existing runner creates a ConfigMap from the `k6` directory and starts k6 as a Kubernetes Job.

No replacement of the following files is required:

```text
scripts/common.sh
scripts/run-k6.sh
k8s/k6/k6-job.yaml
k6/loadtest.js
scripts/run-until-fail.sh
```

Make the benchmark helpers executable after adding them to the repository:

```bash
chmod +x scripts/run-benchmark-suite.sh
chmod +x scripts/run-rps-until-fail.sh
chmod +x scripts/collect-k8s-resources.sh
chmod +x scripts/run-resource-scaling.sh
chmod +x scripts/run-payload-matrix.sh
chmod +x scripts/run-topology-test.sh
chmod +x scripts/summarize-results.py
```

## Benchmark Types

| Test | Main purpose | Load model |
|---|---|---|
| Policy test | Verify expected allow and deny behavior | Small deterministic request set |
| Fixed RPS | Compare models at the same request arrival rate | `constant-arrival-rate` |
| Saturation | Observe degradation while load increases | `ramping-arrival-rate` |
| RPS until failure | Find the first request rate that violates the SLO | Repeated fixed-RPS runs |
| Connection churn | Measure the cost of connection reuse versus new connections | Fixed RPS |
| VU concurrency | Compare behavior under a fixed number of concurrent virtual users | Closed VU model |
| Payload matrix | Compare different request and response sizes | Fixed RPS |
| Resource scaling | Compare CPU, memory, and rollout time as replicas increase | Fixed RPS plus `kubectl top` |
| Topology test | Compare same-node and cross-node traffic | Fixed RPS |

## Policy Verification

Run policy checks for one model:

```bash
bash scripts/run-benchmark-suite.sh baseline policy
bash scripts/run-benchmark-suite.sh ambient-l4 policy
bash scripts/run-benchmark-suite.sh l7-dikastes policy
```

Run policy checks for all models:

```bash
bash scripts/run-benchmark-suite.sh all policy
```

Expected results for the current project policies:

| Request | `baseline` | `ambient-l4` | `l7-dikastes` |
|---|---:|---:|---:|
| `GET /api/data` | 200 | 200 | 200 |
| `GET /health` | 200 | 200 | 200 |
| `POST /api/data` | 200 | 200 | 403 |
| `GET /admin` | 200 | 200 | 403 |

The benchmark scripts mark an expected `403` as a successful policy result. Therefore, correctly blocked traffic does not automatically count as an HTTP failure in the corrected benchmark profiles.

When application behavior or policy rules change, update the test cases or expected-status logic in:

```text
k6/benchmark-common.js
```

## Test Modes

The compatibility script `k6/loadtest.js` supports the following modes.

### Allowed traffic

```bash
TEST_MODE=allowed
```

Sends an allowed request and expects HTTP 200.

### Method-based blocking

```bash
TEST_MODE=blocked
```

Sends `POST /api/data`. The current L7 Dikastes policy is expected to return HTTP 403.

### Path-based blocking

```bash
TEST_MODE=admin-blocked
```

Sends `GET /admin`. The current L7 Dikastes policy is expected to return HTTP 403.

### Mixed traffic

```bash
TEST_MODE=mixed
```

Alternates between allowed requests and requests that should be blocked by the L7 model.

For formal policy comparison, prefer `policy-test.js` because it uses model-aware expected statuses.

## Fixed RPS Benchmark

Run several fixed request rates for one model:

```bash
RATES="50 100 200 400" \
REPEATS=3 \
STEADY_DURATION=2m \
BENCHMARK_VUS=200 \
  bash scripts/run-benchmark-suite.sh baseline steady
```

Run the same matrix for all models:

```bash
RATES="50 100 200 400" \
REPEATS=3 \
STEADY_DURATION=2m \
BENCHMARK_VUS=200 \
  bash scripts/run-benchmark-suite.sh all steady
```

In arrival-rate tests:

- `RPS` is the target request arrival rate for the entire scenario.
- `VUS` is the initial virtual-user pool available to maintain the requested rate.
- k6 can require more VUs when response time increases.
- `dropped_iterations` indicate that the configured arrival rate could not be generated with the available capacity.

A separate warm-up run is recommended before collecting final measurements:

```bash
RPS=200 \
VUS=200 \
DURATION=30s \
TEST_MODE=allowed \
  bash scripts/run-k6.sh baseline steady-rps.js
```

Do not include the warm-up result in the final model comparison.

## Saturation Benchmark

Run a gradual arrival-rate profile:

```bash
SATURATION_MAX_RPS=1000 \
SATURATION_STAGE_DURATION=30s \
  bash scripts/run-benchmark-suite.sh baseline saturation
```

The saturation test contains several stages. `SATURATION_STAGE_DURATION` controls one stage, not the complete test duration.

## Find the Maximum Sustainable RPS

Use repeated fixed-RPS tests to find the first SLO violation:

```bash
START_RPS=50 \
STEP_RPS=50 \
DURATION=1m \
P95_LIMIT_MS=500 \
FAIL_RATE_LIMIT=0.01 \
SUCCESS_RATE_LIMIT=0.99 \
  bash scripts/run-rps-until-fail.sh baseline
```

A run is considered degraded when one or more of the following conditions occur:

- error rate exceeds the configured limit;
- expected-status success rate falls below the configured limit;
- p95 latency exceeds the configured limit;
- dropped iterations appear;
- achieved RPS is below the required fraction of target RPS.

The older `run-until-fail.sh` remains useful for finding a limit by increasing VUs. It measures a different property from the arrival-rate test and can be retained for comparison.

## Connection Reuse Benchmark

```bash
CHURN_RPS=200 \
CHURN_DURATION=2m \
REPEATS=3 \
  bash scripts/run-benchmark-suite.sh all churn
```

The runner executes both variants:

```text
NO_CONNECTION_REUSE=false
NO_CONNECTION_REUSE=true
```

This helps reveal the cost of repeatedly creating TCP connections and service mesh transport sessions.

## VU Concurrency Benchmark

```bash
CONCURRENCY_VUS_LIST="20 50 100 200" \
REPEATS=3 \
  bash scripts/run-benchmark-suite.sh all concurrency
```

This is a closed load model. When the system slows down, each VU completes fewer iterations, so achieved RPS can decrease automatically.

Use it to study concurrent-client behavior, not as a replacement for fixed-RPS comparison.

## Payload and Response Size Matrix

```bash
SIZES="128 16384 262144" \
RPS=200 \
DURATION=2m \
REPEATS=3 \
  bash scripts/run-payload-matrix.sh baseline
```

All sizes are specified in bytes.

## Pod Scaling and Resource Collection

```bash
REPLICAS_LIST="1 5 10" \
RPS=200 \
DURATION=2m \
  bash scripts/run-resource-scaling.sh l7-dikastes
```

The script:

1. records the original server replica count;
2. scales the `server` Deployment;
3. measures rollout duration;
4. runs a fixed-RPS benchmark;
5. collects container and node CPU and memory usage;
6. restores the original replica count.

Results are stored under:

```text
results/<model>/resource-scaling/
```

Run only the resource collector:

```bash
bash scripts/collect-k8s-resources.sh \
  baseline \
  results/baseline/manual-resource-sample \
  5
```

Stop manual collection with `Ctrl+C`.

## Same-Node and Cross-Node Benchmark

```bash
RPS=200 \
DURATION=2m \
REPEATS=3 \
  bash scripts/run-topology-test.sh ambient-l4
```

At least two schedulable Kubernetes nodes are required.

The script temporarily places the client and server on selected nodes, runs the tests, and restores the original Deployment configuration afterward.

## Complete Benchmark Suite

```bash
bash scripts/run-benchmark-suite.sh all all
```

This runs policy, steady-RPS, saturation, connection-churn, and VU-concurrency tests for all models.

The complete suite can take a long time and generate substantial load. Determine a reasonable RPS range with one model before running it across all clusters.

## Environment Variables

### Cluster creation

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
GRAFANA_ADMIN_PASSWORD=admin
```

### Common k6 request settings

```bash
TARGET_URL=http://client:8080/proxy
TEST_MODE=allowed
REQUEST_METHOD=GET
REQUEST_PATH=/api/data
PAYLOAD_SIZE=128
RESPONSE_SIZE=128
SERVER_DELAY_MS=0
TIMEOUT=5s
NO_CONNECTION_REUSE=false
```

### Closed VU profile

```bash
VUS=20
DURATION=30s
SLEEP_MS=100
```

### Arrival-rate profiles

```bash
RPS=100
VUS=100
DURATION=2m
```

### Thresholds

```bash
FAIL_RATE_THRESHOLD=0.05
P95_THRESHOLD_MS=1000
SUCCESS_RATE_THRESHOLD=0.95
```

### Benchmark suite orchestration

```bash
RATES="50 100 200 400"
REPEATS=3
STEADY_DURATION=2m
BENCHMARK_VUS=200
COOLDOWN_SECONDS=10
```

A complete example is available in:

```text
benchmark.env.example
```

## Results

Each k6 run writes a JSON summary under the project `results` directory. The exact subdirectory depends on the model, test type, and run tag.

Important metrics include:

| Metric | Meaning |
|---|---|
| `http_reqs` | Total request count and achieved request rate |
| `http_req_duration` | End-to-end request latency |
| `http_req_failed` | Requests classified as failed by the benchmark expectation |
| `success_rate` | Requests that returned the model-specific expected status |
| `dropped_iterations` | Arrival-rate iterations that k6 could not start |
| `upstream_latency_ms` | Application processing time reported by the test service |
| `infrastructure_overhead_ms` | Approximate request time outside the upstream application, when available |

For performance comparison, report at least:

```text
Target RPS
Achieved RPS
Dropped iterations
Error rate
Expected-status success rate
Latency p50
Latency p95
Latency p99
CPU usage
Memory usage
Maximum sustainable RPS
```

## Generate a Summary CSV

```bash
python3 scripts/summarize-results.py results
```

Default output:

```text
results/benchmark-summary.csv
```

Custom output path:

```bash
python3 scripts/summarize-results.py results \
  --output results/my-summary.csv
```

## Generate Plots

```bash
python3 scripts/plot-results.py \
  --results results \
  --out results/plots
```

## Recommended Experimental Procedure

For a fair comparison:

1. Use the same host, Docker limits, k3d topology, Kubernetes version, and workload manifests for every model.
2. Create only the model being tested, or verify that other clusters do not compete for CPU and memory.
3. Confirm that all Pods are Ready and the cluster is idle before each run.
4. Run one warm-up test and exclude it from the final dataset.
5. Execute each measured scenario at least three times. Five repetitions provide a stronger dataset.
6. Keep payload size, response size, server delay, request path, duration, and thresholds identical across models.
7. Allow a cooldown period between runs.
8. Record host utilization together with Kubernetes container metrics.
9. Compare medians and variability, not only a single best result.
10. Preserve raw JSON summaries so plots and statistical analysis can be reproduced.

## Technical Notes

- Calico Enterprise is not used.
- Calico eBPF replaces kube-proxy, so k3d is created with kube-proxy disabled.
- k3s Flannel and the built-in k3s network policy controller are disabled.
- In the L7 Dikastes model, Calico `bpfConnectTimeLoadBalancing` is set to `Disabled` for compatibility with the selected L7 integration.
- The test application intentionally uses the Python standard library to reduce application-level noise in the measurements.
- The Ambient model does not include a waypoint proxy, so it should not be treated as an L7 policy model.
- The L7 Dikastes model adds per-workload sidecars, while the Ambient model uses node-level `ztunnel` components. Resource scaling results should be interpreted with that architectural difference in mind.
- Results from VU-based and arrival-rate-based tests measure different load models and should not be mixed into one capacity value.

## Legacy Compatibility

The original files can remain available for manual experiments:

```text
k6/loadtest.js
scripts/run-until-fail.sh
```

Use the newer benchmark profiles for formal model comparison because they provide model-aware expected statuses, fixed-RPS workloads, dropped-iteration tracking, resource collection, and consistent result aggregation.
