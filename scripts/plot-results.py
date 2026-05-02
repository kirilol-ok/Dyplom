#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def metric(data: dict[str, Any], name: str, key: str, default: float = 0.0) -> float:
    value = data.get("metrics", {}).get(name, {}).get("values", {}).get(key, default)
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def meta(data: dict[str, Any], key: str, default: str = "") -> str:
    value = data.get("diploma", {}).get(key, default)
    return str(value) if value is not None else default


def parse_rows(results_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(results_dir.rglob("*-summary.json")):
        data = load_json(path)
        rows.append(
            {
                "file": str(path),
                "model": meta(data, "model", path.parent.name),
                "test_mode": meta(data, "testMode", ""),
                "vus": meta(data, "vus", ""),
                "duration": meta(data, "duration", ""),
                "payload_size": meta(data, "payloadSize", ""),
                "response_size": meta(data, "responseSize", ""),
                "http_reqs": metric(data, "http_reqs", "count"),
                "rps": metric(data, "http_reqs", "rate"),
                "fail_rate": metric(data, "http_req_failed", "rate"),
                "success_rate": metric(data, "success_rate", "rate"),
                "http_avg_ms": metric(data, "http_req_duration", "avg"),
                "http_p50_ms": metric(data, "http_req_duration", "med"),
                "http_p90_ms": metric(data, "http_req_duration", "p(90)"),
                "http_p95_ms": metric(data, "http_req_duration", "p(95)"),
                "http_p99_ms": metric(data, "http_req_duration", "p(99)"),
                "upstream_p95_ms": metric(data, "upstream_latency_ms", "p(95)"),
                "data_sent": metric(data, "data_sent", "count"),
                "data_received": metric(data, "data_received", "count"),
            }
        )
    return rows


def write_csv(rows: list[dict[str, Any]], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        return
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def sort_key(row: dict[str, Any]) -> tuple[str, int]:
    try:
        vus = int(row.get("vus") or 0)
    except ValueError:
        vus = 0
    return str(row["model"]), vus


def line_plot(rows: list[dict[str, Any]], y_key: str, y_label: str, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(str(row["model"]), []).append(row)

    plt.figure(figsize=(10, 6))
    for model, model_rows in sorted(grouped.items()):
        model_rows = sorted(model_rows, key=sort_key)
        xs = []
        ys = []
        for item in model_rows:
            try:
                xs.append(int(item.get("vus") or 0))
                ys.append(float(item.get(y_key) or 0))
            except ValueError:
                continue
        if xs:
            plt.plot(xs, ys, marker="o", label=model)

    plt.title(y_label)
    plt.xlabel("Virtual users")
    plt.ylabel(y_label)
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_path, dpi=160)
    plt.close()


def bar_plot_latest(rows: list[dict[str, Any]], y_key: str, y_label: str, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    latest_by_model: dict[str, dict[str, Any]] = {}
    for row in rows:
        latest_by_model[str(row["model"])] = row

    labels = list(latest_by_model.keys())
    values = [float(latest_by_model[label].get(y_key) or 0) for label in labels]

    plt.figure(figsize=(10, 6))
    plt.bar(labels, values)
    plt.title(y_label)
    plt.ylabel(y_label)
    plt.xticks(rotation=15, ha="right")
    plt.tight_layout()
    plt.savefig(out_path, dpi=160)
    plt.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", default="results", help="Results directory")
    parser.add_argument("--out", default="results/plots", help="Output directory for CSV and PNG files")
    args = parser.parse_args()

    results_dir = Path(args.results)
    out_dir = Path(args.out)
    rows = parse_rows(results_dir)
    if not rows:
        print(f"No *-summary.json files found in {results_dir}")
        return 1

    csv_path = out_dir / "summary-table.csv"
    write_csv(rows, csv_path)

    line_plot(rows, "http_p95_ms", "HTTP latency p95, ms", out_dir / "latency-p95-by-vus.png")
    line_plot(rows, "rps", "HTTP requests per second", out_dir / "rps-by-vus.png")
    line_plot(rows, "fail_rate", "HTTP fail rate", out_dir / "fail-rate-by-vus.png")
    line_plot(rows, "success_rate", "Expected success rate", out_dir / "success-rate-by-vus.png")
    bar_plot_latest(rows, "data_sent", "Data sent, bytes", out_dir / "data-sent-latest.png")
    bar_plot_latest(rows, "data_received", "Data received, bytes", out_dir / "data-received-latest.png")

    print(f"Saved CSV: {csv_path}")
    print(f"Saved plots to: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
