#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


def metric(data: dict[str, Any], name: str, key: str, default: Any = "") -> Any:
    try:
        return data["metrics"][name]["values"][key]
    except (KeyError, TypeError):
        return default


def load_summary(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None

    if not isinstance(data, dict) or "metrics" not in data or "diploma" not in data:
        return None

    return data


def row_from_summary(path: Path, data: dict[str, Any]) -> dict[str, Any]:
    cfg = data.get("diploma", {})
    return {
        "file": str(path),
        "model": cfg.get("model", ""),
        "profile": cfg.get("profile", ""),
        "test_mode": cfg.get("testMode", ""),
        "target_url": cfg.get("targetUrl", ""),
        "configured_rps": cfg.get("rps", ""),
        "vus": cfg.get("vus", ""),
        "duration": cfg.get("duration", ""),
        "request_method": cfg.get("requestMethod", ""),
        "request_path": cfg.get("requestPath", ""),
        "payload_size": cfg.get("payloadSize", ""),
        "response_size": cfg.get("responseSize", ""),
        "server_delay_ms": cfg.get("serverDelayMs", ""),
        "no_connection_reuse": cfg.get("noConnectionReuse", ""),
        "achieved_rps": metric(data, "http_reqs", "rate"),
        "http_avg_ms": metric(data, "http_req_duration", "avg"),
        "http_p50_ms": metric(data, "http_req_duration", "med"),
        "http_p95_ms": metric(data, "http_req_duration", "p(95)"),
        "http_p99_ms": metric(data, "http_req_duration", "p(99)"),
        "http_fail_rate": metric(data, "http_req_failed", "rate"),
        "expected_status_rate": metric(
            data,
            "expected_status_rate",
            "rate",
            metric(data, "success_rate", "rate"),
        ),
        "dropped_iterations": metric(data, "dropped_iterations", "count", 0),
        "upstream_avg_ms": metric(data, "upstream_latency_ms", "avg"),
        "upstream_p95_ms": metric(data, "upstream_latency_ms", "p(95)"),
        "overhead_avg_ms": metric(data, "infrastructure_overhead_ms", "avg"),
        "overhead_p95_ms": metric(data, "infrastructure_overhead_ms", "p(95)"),
        "data_received_bytes": metric(data, "data_received", "count"),
        "data_sent_bytes": metric(data, "data_sent", "count"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate k6 summary JSON files into CSV.")
    parser.add_argument("results_dir", nargs="?", default="results", type=Path)
    parser.add_argument("--output", "-o", default=None, type=Path)
    args = parser.parse_args()

    results_dir: Path = args.results_dir
    output = args.output or results_dir / "benchmark-summary.csv"

    rows: list[dict[str, Any]] = []
    for path in sorted(results_dir.rglob("*.json")):
        data = load_summary(path)
        if data is not None:
            rows.append(row_from_summary(path, data))

    if not rows:
        print(f"No k6 summary files found under {results_dir}")
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"Saved {len(rows)} rows to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
