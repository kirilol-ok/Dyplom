#!/usr/bin/env python3
"""Record before/after cAdvisor CFS counters without polling during the benchmark.

Some k3s installations do not expose cAdvisor counters through the API server.
In that case, an exec-based cgroup v2 fallback captures the benchmark server only.
Absent counters are reported as unavailable, never as zero throttling.
"""
import argparse
import csv
import json
import re
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

METRICS = {
    "container_cpu_cfs_periods_total": "periods",
    "container_cpu_cfs_throttled_periods_total": "throttled_periods",
    "container_cpu_cfs_throttled_seconds_total": "throttled_seconds",
}
SAMPLE_RE = re.compile(r"^(container_cpu_cfs_(?:periods_total|throttled_periods_total|throttled_seconds_total))\{(.*?)\}\s+([0-9.eE+-]+)(?:\s|$)")
LABEL_RE = re.compile(r'([a-zA-Z_][\w]*)="((?:\\.|[^"\\])*)"')


def run(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=25, check=False)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def labels_of(blob):
    return {k: v.replace('\\"', '"').replace('\\\\', '\\') for k, v in LABEL_RE.findall(blob)}


def parse_cadvisor(raw, node):
    containers = {}
    for line in raw.splitlines():
        match = SAMPLE_RE.match(line)
        if not match:
            continue
        metric, labels, value = match.groups()
        attrs = labels_of(labels)
        namespace = attrs.get("namespace", "")
        pod = attrs.get("pod", "")
        container = attrs.get("container", "")
        if not namespace or not pod or not container or container == "POD":
            continue
        key = f"cadvisor|{node}|{namespace}|{pod}|{container}|{attrs.get('id', '')}"
        entry = containers.setdefault(key, {
            "namespace": namespace, "pod": pod, "container": container,
            "source": "cadvisor", "counters": {},
        })
        entry["counters"][METRICS[metric]] = float(value)
    return containers


def snapshot(path, namespace, k6_pod=""):
    output = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "samples": {}, "errors": []}
    raw_nodes = run(["kubectl", "get", "nodes", "-o", "json"])
    if raw_nodes:
        try:
            nodes = json.loads(raw_nodes).get("items", [])
        except json.JSONDecodeError:
            nodes = []
        for item in nodes:
            node = item.get("metadata", {}).get("name", "")
            if not node:
                continue
            # Query once before and once after the run; never poll cAdvisor mid-test.
            raw = run(["kubectl", "--request-timeout=15s", "get", "--raw", f"/api/v1/nodes/{node}/proxy/metrics/cadvisor"])
            if not raw:
                output["errors"].append(f"cAdvisor unavailable on {node}")
                continue
            for key, entry in parse_cadvisor(raw, node).items():
                if entry["container"] == "k6" and k6_pod and entry["pod"] != k6_pod:
                    continue
                output["samples"][key] = entry
    else:
        output["errors"].append("Could not list Kubernetes nodes")

    # Supports BusyBox app images and Windows Git Bash because kubectl is invoked
    # directly from Python (no MSYS path rewriting of /sys/fs/cgroup).
    server_stat = run([
        "kubectl", "exec", "-n", namespace, "deployment/server", "-c", "server", "--",
        "cat", "/sys/fs/cgroup/cpu.stat",
    ])
    if server_stat:
        counters = {}
        for line in server_stat.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            if parts[0] == "nr_periods":
                counters["periods"] = float(parts[1])
            elif parts[0] == "nr_throttled":
                counters["throttled_periods"] = float(parts[1])
            elif parts[0] == "throttled_usec":
                counters["throttled_seconds"] = float(parts[1]) / 1_000_000
        if len(counters) == 3:
            output["samples"]["cgroup-server"] = {
                "namespace": namespace, "pod": "server", "container": "server",
                "source": "cgroup-v2", "counters": counters,
            }
    else:
        output["errors"].append("Server cgroup v2 counters unavailable")

    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(f"Throttling snapshot: {len(output['samples'])} counter series, {len(output['errors'])} warnings")


def classify(namespace, pod, container):
    p, c, ns = pod.lower(), container.lower(), namespace.lower()
    if "waypoint" in p:
        return "waypoint"
    if p.startswith("ztunnel"):
        return "ztunnel"
    if p.startswith("istiod"):
        return "istiod"
    if p.startswith("istio-cni"):
        return "istio-cni"
    if c == "dikastes":
        return "dikastes"
    if c == "istio-proxy":
        return "envoy-sidecar"
    if p.startswith("calico-node"):
        return "calico-dataplane"
    if ns in {"calico-system", "tigera-operator"} or p.startswith(("calico-", "tigera-")):
        return "calico-control"
    if p.startswith("server") and c == "server":
        return "app-server"
    if p.startswith("client") and c == "client":
        return "app-client"
    if p.startswith("k6-") and c == "k6":
        return "load-generator"
    return "other"


def append_rows(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0])
    if path.exists() and path.stat().st_size:
        with path.open(newline="", encoding="utf-8") as file:
            reader = csv.DictReader(file)
            existing_fields = reader.fieldnames or []
            old_rows = list(reader)
        if existing_fields != fieldnames:
            unknown = set(existing_fields) - set(fieldnames)
            if unknown:
                raise RuntimeError(f"Unexpected columns in {path}: {unknown}")
            with path.open("w", newline="", encoding="utf-8") as file:
                writer = csv.DictWriter(file, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(old_rows)
    exists = path.exists() and path.stat().st_size > 0
    with path.open("a", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        if not exists:
            writer.writeheader()
        writer.writerows(rows)


def summarize(before_path, after_path, master, metadata_file, config_file, run_id, model, profile):
    before = json.loads(Path(before_path).read_text(encoding="utf-8"))["samples"]
    after = json.loads(Path(after_path).read_text(encoding="utf-8"))["samples"]
    meta = json.loads(Path(metadata_file).read_text(encoding="utf-8"))
    config = json.loads(Path(config_file).read_text(encoding="utf-8"))

    # benchmark-metadata includes regular containers and native sidecars
    # (initContainers with restartPolicy=Always). Do not count one-shot init
    # containers as running workloads or they would inflate expectations.
    expected = defaultdict(int)
    for entry in config["containers"]:
        group = entry.get("group", "other")
        if group != "other":
            expected[group] += int(entry["replicas"])

    aggregated = defaultdict(lambda: {"periods": 0, "throttled_periods": 0, "throttled_seconds": 0.0, "seen": set(), "source": set()})
    for key in set(before) & set(after):
        a, b = before[key], after[key]
        # Prefer native cAdvisor counters for server when available in both snapshots.
        if key == "cgroup-server" and any(
            entry["container"] == "server" and entry["namespace"] == a["namespace"]
            and entry["source"] == "cadvisor" for k, entry in after.items()
            if k in before and set(before[k]["counters"]) == set(METRICS.values())
        ):
            continue
        a_values, b_values = a["counters"], b["counters"]
        if not all(k in a_values and k in b_values for k in ("periods", "throttled_periods", "throttled_seconds")):
            continue
        delta = {name: b_values[name] - a_values[name] for name in ("periods", "throttled_periods", "throttled_seconds")}
        if any(value < 0 for value in delta.values()):
            continue  # Counter reset / restarted container; do not report fake deltas.
        group = classify(a["namespace"], a["pod"], a["container"])
        if group == "other":
            continue
        record = aggregated[group]
        for name in delta:
            record[name] += delta[name]
        record["seen"].add((a["namespace"], a["pod"], a["container"]))
        record["source"].add(a["source"])

    rows = []
    for group in sorted(set(expected) | set(aggregated)):
        values = aggregated[group]
        measured = len(values["seen"])
        planned = expected.get(group, 0)
        periods = values["periods"]
        if measured == 0:
            status = "unavailable"
        elif planned == 0:
            status = "untracked"
        elif measured < planned:
            status = "partial"
        elif measured > planned:
            status = "mismatch"
        else:
            status = "ok"
        rows.append({
            "run_id": run_id,
            "model": model,
            "profile": profile,
            "config_id": meta["config_id"],
            "component_group": group,
            "status": status,
            "containers_measured": measured,
            "containers_expected": planned,
            "nr_periods_delta": int(periods) if measured else "",
            "nr_throttled_delta": int(values["throttled_periods"]) if measured else "",
            "throttled_periods_pct": round(values["throttled_periods"] / periods * 100, 4) if periods else "",
            "throttled_seconds_delta": round(values["throttled_seconds"], 6) if measured else "",
            "source": "+".join(sorted(values["source"])),
        })
    if rows:
        append_rows(master, rows)
    print(f"Throttling rows: {len(rows)}, groups unavailable: {sum(r['status'] == 'unavailable' for r in rows)}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--output", required=True)
    snap.add_argument("--namespace", default="test-app")
    snap.add_argument("--k6-pod", default="")
    report = sub.add_parser("report")
    for flag in ("before", "after", "master", "metadata", "config", "run-id", "model", "profile"):
        report.add_argument("--" + flag, required=True)
    args = parser.parse_args()
    if args.action == "snapshot":
        snapshot(args.output, args.namespace, args.k6_pod)
    else:
        summarize(args.before, args.after, args.master, args.metadata, args.config,
                  args.run_id, args.model, args.profile)


if __name__ == "__main__":
    main()
