# Experimental architecture

## Matrix

```text
                         POLICY LEVEL
                    None       L4        L7

CALICO              C0         C1        C2
                    |          |         |
                    |          |         +-- Envoy + Dikastes + Calico HTTP policy
                    |          +------------ Calico NetworkPolicy
                    +----------------------- Calico eBPF, no policy

ISTIO AMBIENT       I0         I1        I2
                    |          |         |
                    |          |         +-- ztunnel + L4 policy + waypoint + L7 policy
                    |          +------------ ztunnel + L4 AuthorizationPolicy
                    +----------------------- ztunnel, no AuthorizationPolicy
```

## Direct comparisons

```text
C0 <-> I0   dataplane / mesh baseline comparison
C1 <-> I1   L4 enforcement comparison
C2 <-> I2   L7 enforcement comparison
```

## Within-track overhead

```text
C1 - C0   additional Calico L4 enforcement cost
C2 - C1   additional Calico L7 architecture cost

I1 - I0   additional Ambient L4 policy cost
I2 - I1   additional waypoint/L7 cost
```

## Benchmark traffic path

The k6 pod is the load-generating client and targets the `server` Kubernetes Service directly.

Default topology uses one k3d server node and one k3d agent node. The k6 Job has required pod anti-affinity against the server workload, so the request path crosses nodes when both nodes are schedulable.

### C0

```text
k6 -> Calico eBPF -> server
```

### C1

```text
k6 -> Calico eBPF -> Calico L4 policy -> server
```

### C2

```text
k6 + Envoy -> network -> server Envoy -> Dikastes -> Calico policy decision -> server
```

### I0

```text
k6 -> source ztunnel -> HBONE -> destination ztunnel -> server
```

### I1

```text
k6 -> source ztunnel -> HBONE -> destination ztunnel + L4 AuthorizationPolicy -> server
```

### I2

```text
k6 -> source ztunnel -> HBONE -> service waypoint + L7 AuthorizationPolicy -> destination ztunnel + L4 AuthorizationPolicy -> server
```

## Complex policy scenarios

### L4 attack

The L4 models receive two concurrent open-model streams from k6. Both streams create new connections:

```text
allowed stream -> server:8080 -> accepted
blocked stream -> server:8081 -> denied by L4 policy
```

The total RPS and blocked percentage are recorded in the summary CSV. Separate custom metrics prevent expected L4 failures from being mixed with latency for accepted requests.

### L7 spaghetti policy

The L7 models are measured twice with an identical traffic mix:

```text
simple policy     -> allowed GET + blocked POST
spaghetti policy -> allowed GET + blocked POST
```

The Calico variant contains many HTTP allow clauses and relies on implicit deny for unmatched traffic. The Ambient variant combines many DENY and ALLOW rules at the service waypoint. The runner restores the simple policy after the comparison.
