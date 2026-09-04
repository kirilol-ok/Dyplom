#!/usr/bin/env python3
import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt

MODEL_LABELS = {
    "calico-baseline": "Calico baseline",
    "calico-l4": "Calico L4",
    "calico-l7": "Calico L7 (Dikastes)",
    "ambient-baseline": "Ambient baseline",
    "ambient-l4": "Ambient L4",
    "ambient-l7": "Ambient L7 (Waypoint)",
}

FAMILY_MODELS = {
    "calico": ["calico-baseline", "calico-l4", "calico-l7"],
    "ambient": ["ambient-baseline", "ambient-l4", "ambient-l7"],
}


def read_csv(path):
    path = Path(path)
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def aggregate_latency(rows, model):
    grouped = defaultdict(lambda: {"p5": [], "p50": [], "p95": []})
    for row in rows:
        if row.get("model") != model or row.get("profile") != "steady-rps":
            continue
        rps = number(row.get("configured_rps"))
        p5 = number(row.get("http_p5_ms"))
        p50 = number(row.get("http_p50_ms"))
        p95 = number(row.get("http_p95_ms"))
        if None in (rps, p5, p50, p95):
            continue
        grouped[rps]["p5"].append(p5)
        grouped[rps]["p50"].append(p50)
        grouped[rps]["p95"].append(p95)

    x = sorted(grouped)
    low = [statistics.median(grouped[r]["p5"]) for r in x]
    median = [statistics.median(grouped[r]["p50"]) for r in x]
    high = [statistics.median(grouped[r]["p95"]) for r in x]
    return x, low, median, high


def plot_latency(summary_rows, family, output):
    fig, ax = plt.subplots(figsize=(10, 6))
    has_data = False

    for model in FAMILY_MODELS[family]:
        x, low, median, high = aggregate_latency(summary_rows, model)
        if not x:
            continue
        has_data = True
        ax.plot(x, median, marker="o", label=MODEL_LABELS[model])
        ax.fill_between(x, low, high, alpha=0.15)

    if not has_data:
        plt.close(fig)
        return False

    title_family = "Calico" if family == "calico" else "Istio Ambient"
    ax.set_title(f"{title_family}: median latency with p5-p95 ribbon")
    ax.set_xlabel("Target RPS")
    ax.set_ylabel("HTTP request latency [ms]")
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(output, dpi=160)
    plt.close(fig)
    return True


def aggregate_resource(rows, component_group, metric):
    grouped = defaultdict(list)
    for row in rows:
        if row.get("profile") != "steady-rps":
            continue
        if row.get("component_group") != component_group:
            continue
        model = row.get("model")
        rps = number(row.get("configured_rps"))
        value = number(row.get(metric))
        if model and rps is not None and value is not None:
            grouped[(model, rps)].append(value)
    return grouped


def plot_resource(resource_rows, component_group, metric, ylabel, title, output):
    grouped = aggregate_resource(resource_rows, component_group, metric)
    fig, ax = plt.subplots(figsize=(10, 6))
    has_data = False

    for model in MODEL_LABELS:
        points = []
        for (row_model, rps), values in grouped.items():
            if row_model == model:
                points.append((rps, statistics.median(values)))
        points.sort()
        if not points:
            continue
        has_data = True
        ax.plot([p[0] for p in points], [p[1] for p in points], marker="o", label=MODEL_LABELS[model])

    if not has_data:
        plt.close(fig)
        return False

    ax.set_title(title)
    ax.set_xlabel("Target RPS")
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(output, dpi=160)
    plt.close(fig)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", default="results/benchmark-summary.csv")
    parser.add_argument("--resources", default="results/benchmark-resources.csv")
    parser.add_argument("--out", default="results/plots")
    args = parser.parse_args()

    summary_rows = read_csv(args.summary)
    resource_rows = read_csv(args.resources)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    generated = []

    path = out / "steady-calico-latency.png"
    if plot_latency(summary_rows, "calico", path):
        generated.append(path)

    path = out / "steady-ambient-latency.png"
    if plot_latency(summary_rows, "ambient", path):
        generated.append(path)

    plots = [
        ("benchmark-total", "cpu_mean_mcores", "CPU [millicores]", "Steady load: benchmark CPU excluding k6", "steady-total-cpu.png"),
        ("benchmark-total", "memory_mean_mib", "Memory [MiB]", "Steady load: benchmark memory excluding k6", "steady-total-memory.png"),
        ("network-stack-total", "cpu_mean_mcores", "CPU [millicores]", "Steady load: network/security stack CPU", "steady-network-stack-cpu.png"),
        ("network-stack-total", "memory_mean_mib", "Memory [MiB]", "Steady load: network/security stack memory", "steady-network-stack-memory.png"),
    ]

    for component, metric, ylabel, title, filename in plots:
        path = out / filename
        if plot_resource(resource_rows, component, metric, ylabel, title, path):
            generated.append(path)

    if not generated:
        raise SystemExit("No compatible benchmark data found")

    for path in generated:
        print(path)


if __name__ == "__main__":
    main()
