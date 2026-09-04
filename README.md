# Diploma Kubernetes policy benchmark v2

This project implements two parallel experimental tracks for a Kubernetes diploma benchmark:

| Level | Calico track | Istio Ambient track |
| --- | --- | --- |
| Baseline | `calico-baseline` | `ambient-baseline` |
| L4 | `calico-l4` | `ambient-l4` |
| L7 | `calico-l7` | `ambient-l7` |

The intent is to compare the cost of adding policy enforcement step by step, rather than searching for an absolute saturation boundary.

## Model definitions

### Calico track

`calico-baseline`
- k3d/k3s
- Calico Open Source eBPF dataplane
- no user-defined NetworkPolicy
- no service mesh

`calico-l4`
- same base cluster as `calico-baseline`
- Calico L3/L4 NetworkPolicy on the server workload

`calico-l7`
- Calico eBPF
- Istio sidecar mode
- Envoy sidecars
- Dikastes on the protected server workload
- Calico HTTP policy enforced through Envoy external authorization

### Istio Ambient track

`ambient-baseline`
- Calico eBPF as CNI/dataplane
- Istio Ambient mode
- ztunnel
- no AuthorizationPolicy
- no waypoint

`ambient-l4`
- same Ambient base
- ztunnel
- Istio L4 AuthorizationPolicy
- no waypoint

`ambient-l7`
- same Ambient base
- ztunnel
- ztunnel L4 AuthorizationPolicy on the protected workload
- service waypoint proxy
- Istio L7 AuthorizationPolicy attached to the `server` Service with `targetRefs`

Dikastes is deliberately not used in the Ambient L7 model.

## Main benchmark scenarios

The main benchmark suite contains only the scenarios currently required by the experiment design:

1. `steady` - fixed arrival-rate load at several RPS levels.
2. `churn` - connection reuse versus disabled connection reuse.
3. `verify` - lightweight policy correctness checks. This is environment verification, not a performance result.

Saturation-search and VU-sweep scenarios are intentionally not part of this version.

The future complex L4 attack scenario and future L7 spaghetti-policy scenario are intentionally not included yet.

## Default steady-load matrix

The default values are conservative and can be changed without editing files:

```bash
RATES="100 200 300 400 500"
REPEATS=3
STEADY_DURATION=45s
BENCHMARK_VUS=300
```

Run a short pilot first if the hardware or Kubernetes version changes.

## Requirements

Host tools:

```text
bash
kubectl
k3d
docker
istioctl
python3
```

For plot generation:

```bash
python3 -m pip install -r requirements.txt
```

The scripts install Calico and, where required, Istio and Gateway API resources from their upstream locations.

## Build one model

Recommended workflow is to create and test one clean model at a time.

```bash
bash scripts/up.sh calico-baseline
bash scripts/up.sh calico-l4
bash scripts/up.sh calico-l7

bash scripts/up.sh ambient-baseline
bash scripts/up.sh ambient-l4
bash scripts/up.sh ambient-l7
```

Legacy aliases are accepted where they are unambiguous:

```text
baseline              -> calico-baseline
baseline-calico-ebpf  -> calico-baseline
l7-dikastes           -> calico-l7
istio-l7-dikastes     -> calico-l7
istio-ambient-l4      -> ambient-l4
```

The old ambiguous alias `l4` is intentionally not accepted because there are now two separate L4 tracks.

## Check model state

```bash
bash scripts/status.sh calico-baseline
bash scripts/status.sh ambient-l7
```

The status command prints workloads, Calico policies, Istio policies, waypoints, and relevant control-plane components.

## Run policy verification

```bash
bash scripts/run-benchmark-suite.sh calico-baseline verify
bash scripts/run-benchmark-suite.sh calico-l4 verify
bash scripts/run-benchmark-suite.sh calico-l7 verify
bash scripts/run-benchmark-suite.sh ambient-baseline verify
bash scripts/run-benchmark-suite.sh ambient-l4 verify
bash scripts/run-benchmark-suite.sh ambient-l7 verify
```

Expected behavior:

| Model | Allowed GET :8080 | GET :8081 | POST /api/data |
| --- | ---: | ---: | ---: |
| calico-baseline | 200 | 200 | 200 |
| calico-l4 | 200 | blocked | not a main check |
| calico-l7 | 200 | blocked by selected policy | 403 |
| ambient-baseline | 200 | 200 | 200 |
| ambient-l4 | 200 | blocked | not a main check |
| ambient-l7 | 200 | not a main check | 403 |

## Run steady load

One model:

```bash
bash scripts/run-benchmark-suite.sh calico-baseline steady
```

Custom RPS range:

```bash
RATES="100 200 300 400 500" \
REPEATS=3 \
STEADY_DURATION=45s \
BENCHMARK_VUS=300 \
bash scripts/run-benchmark-suite.sh ambient-l7 steady
```

The k6 load-generator pod is scheduled away from the server pod when the two-node default topology is used. This makes the benchmark exercise an inter-node network path.

## Run connection churn

```bash
CHURN_RPS=200 \
CHURN_DURATION=45s \
REPEATS=3 \
bash scripts/run-benchmark-suite.sh calico-l4 churn
```

By default the suite runs both normal connection reuse and `noConnectionReuse=true` so the connection-churn effect can be measured against its own control.

## Run the complete current matrix sequentially

This helper creates one clean model, verifies it, runs steady load and churn, then deletes the cluster before moving to the next model:

```bash
bash scripts/run-full-matrix.sh
```

Override values as normal environment variables:

```bash
RATES="100 200 300 400 500" REPEATS=3 bash scripts/run-full-matrix.sh
```

Set `CLEANUP_AFTER_MODEL=false` only when you explicitly want to keep the most recently created clusters.

## Results

Per-run files are stored under:

```text
results/<model>/
```

Typical files:

```text
*.log
*-summary.json
*-raw.json
*-resources.csv
*-resource-summary.csv
```

Master CSV files:

```text
results/benchmark-summary.csv
results/benchmark-resources.csv
```

The steady-load summary stores at least:

```text
RPS
achieved RPS
request count
dropped iterations
HTTP failure rate
p5
median
p95
p99
max
```

The p5 value was added specifically so the final latency plot can show a median line over a p5-p95 ribbon.

## CPU and RAM collection

Resource collection is enabled by default during every k6 run:

```bash
RESOURCE_CSV_ENABLED=true
RESOURCE_SAMPLE_SECONDS=2
```

The collector uses `kubectl top pod -A --containers` and `kubectl top nodes`. It records application containers, Calico, Envoy, Dikastes, ztunnel, waypoint, Istiod and the load generator when metrics are available.

Disable it only for troubleshooting:

```bash
RESOURCE_CSV_ENABLED=false bash scripts/run-benchmark-suite.sh calico-baseline steady
```

## Generate plots

```bash
python3 scripts/plot-results.py \
  --summary results/benchmark-summary.csv \
  --resources results/benchmark-resources.csv \
  --out results/plots
```

Generated plots include:

```text
steady-calico-latency.png
steady-ambient-latency.png
steady-total-cpu.png
steady-total-memory.png
```

The latency plots use target RPS on the X axis, median latency as the central line, and a p5-p95 ribbon.

## Stop or delete a model

```bash
bash scripts/down.sh calico-l4 soft
bash scripts/down.sh calico-l4 hard
bash scripts/down.sh all hard
```

## Reproducibility notes

- Baseline models contain no user-defined policy objects.
- `ambient-baseline` still has ztunnel/HBONE overhead because it is a mesh baseline, not a no-mesh baseline.
- `ambient-l4` uses Istio AuthorizationPolicy. It does not use the Calico L4 policy file.
- `ambient-l7` keeps the L4 policy and adds a waypoint plus an L7 policy. It does not use Dikastes.
- `calico-l7` uses Envoy + Dikastes because Dikastes is the Calico application-layer policy decision component integrated with Istio Envoy.
- Calico eBPF connect-time load balancing is disabled only for models where Istio Ambient or Dikastes requires that compatibility mode.
- Use the same host, Docker resource limits, k3d topology, k6 parameters and `istioctl` version for all final measurements.
