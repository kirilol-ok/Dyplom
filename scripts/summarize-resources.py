#!/usr/bin/env python3
import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

NETWORK_GROUPS = {
    "calico-dataplane",
    "calico-control",
    "envoy-sidecar",
    "dikastes",
    "ztunnel",
    "waypoint",
    "istiod",
    "istio-cni",
}
WORKLOAD_GROUPS = {"app-server", "app-client"}


def classify(namespace, pod, container):
    p = pod.lower()
    c = container.lower()
    ns = namespace.lower()

    if p.startswith("server-waypoint") or "waypoint" in p:
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
    if ns == "calico-system" or ns == "tigera-operator" or p.startswith("calico-") or p.startswith("tigera-"):
        return "calico-control"
    if p.startswith("server-") and c == "server":
        return "app-server"
    if p.startswith("client-") and c == "client":
        return "app-client"
    if p.startswith("k6-") and c == "k6":
        return "load-generator"
    return "other"


def append_rows(path, rows):
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys())
    exists = path.exists() and path.stat().st_size > 0
    if exists:
        with path.open(newline="", encoding="utf-8") as handle:
            existing = next(csv.reader(handle), [])
        if existing != fieldnames:
            raise SystemExit(
                f"CSV schema mismatch in {path}. Move the old file away before mixing v1 and v2 results."
            )

    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        if not exists:
            writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--master", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--rps", required=True)
    parser.add_argument("--no-connection-reuse", required=True)
    args = parser.parse_args()

    per_timestamp = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0]))

    path = Path(args.input)
    if path.exists():
        with path.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                if row.get("scope") != "container":
                    continue
                group = classify(row.get("namespace", ""), row.get("pod", ""), row.get("container", ""))
                ts = row.get("timestamp_utc", "")
                per_timestamp[ts][group][0] += float(row.get("cpu_mcores") or 0)
                per_timestamp[ts][group][1] += float(row.get("memory_mib") or 0)

    # Add derived totals for each sample timestamp.
    for _ts, groups in per_timestamp.items():
        network_cpu = sum(values[0] for group, values in groups.items() if group in NETWORK_GROUPS)
        network_mem = sum(values[1] for group, values in groups.items() if group in NETWORK_GROUPS)
        workload_cpu = sum(values[0] for group, values in groups.items() if group in WORKLOAD_GROUPS)
        workload_mem = sum(values[1] for group, values in groups.items() if group in WORKLOAD_GROUPS)
        groups["network-stack-total"] = [network_cpu, network_mem]
        groups["workload-total"] = [workload_cpu, workload_mem]
        groups["benchmark-total"] = [network_cpu + workload_cpu, network_mem + workload_mem]

    series = defaultdict(lambda: {"cpu": [], "memory": []})
    for groups in per_timestamp.values():
        for group, (cpu, memory) in groups.items():
            if group == "other":
                continue
            series[group]["cpu"].append(cpu)
            series[group]["memory"].append(memory)

    rows = []
    for group in sorted(series):
        cpu = series[group]["cpu"]
        memory = series[group]["memory"]
        if not cpu:
            continue
        rows.append({
            "run_id": args.run_id,
            "model": args.model,
            "profile": args.profile,
            "configured_rps": args.rps,
            "no_connection_reuse": args.no_connection_reuse,
            "component_group": group,
            "samples": len(cpu),
            "cpu_mean_mcores": round(statistics.fmean(cpu), 6),
            "cpu_max_mcores": round(max(cpu), 6),
            "memory_mean_mib": round(statistics.fmean(memory), 6),
            "memory_max_mib": round(max(memory), 6),
        })

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as handle:
        if rows:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        else:
            handle.write("run_id,model,profile,configured_rps,no_connection_reuse,component_group,samples,cpu_mean_mcores,cpu_max_mcores,memory_mean_mib,memory_max_mib\n")

    append_rows(Path(args.master), rows)


if __name__ == "__main__":
    main()
