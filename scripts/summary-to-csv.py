#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path


def metric(data, name, key, default=""):
    return data.get("metrics", {}).get(name, {}).get("values", {}).get(key, default)


def family_level(model):
    if model.startswith("calico-"):
        family = "calico"
    elif model.startswith("ambient-"):
        family = "ambient"
    else:
        family = "unknown"

    if model.endswith("baseline"):
        level = "baseline"
    elif model.endswith("l4"):
        level = "l4"
    elif model.endswith("l7"):
        level = "l7"
    else:
        level = "unknown"
    return family, level


def percent(value):
    if value == "":
        return ""
    return round(float(value) * 100.0, 6)


def append_row(path, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(row.keys())
    exists = path.exists() and path.stat().st_size > 0
    if exists:
        with path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            existing = reader.fieldnames or []
            existing_rows = list(reader)
        if existing != fieldnames:
            unknown = [name for name in existing if name not in fieldnames]
            if unknown:
                raise SystemExit(
                    f"CSV schema mismatch in {path}. Unknown existing columns: {', '.join(unknown)}"
                )

            temporary = path.with_name(f".{path.name}.schema-upgrade.tmp")
            with temporary.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(existing_rows)
            temporary.replace(path)

    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("summary")
    parser.add_argument("csv")
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    with open(args.summary, encoding="utf-8") as handle:
        data = json.load(handle)

    diploma = data.get("diploma", {})
    model = str(diploma.get("model", "unknown"))
    family, level = family_level(model)

    row = {
        "run_id": args.run_id,
        "model": model,
        "family": family,
        "level": level,
        "profile": diploma.get("profile", ""),
        "test_mode": diploma.get("testMode", ""),
        "scenario_variant": diploma.get("scenarioVariant", ""),
        "configured_rps": diploma.get("rps", ""),
        "allowed_rps": diploma.get("allowedRps", ""),
        "blocked_rps": diploma.get("blockedRps", ""),
        "achieved_rps": metric(data, "http_reqs", "rate"),
        "configured_vus": diploma.get("vus", ""),
        "configured_duration": diploma.get("duration", ""),
        "no_connection_reuse": diploma.get("noConnectionReuse", ""),
        "http_reqs": metric(data, "http_reqs", "count"),
        "dropped_iterations": metric(data, "dropped_iterations", "count", 0),
        "expected_status_pct": percent(metric(data, "expected_status_rate", "rate", 1)),
        "http_failed_pct": percent(metric(data, "http_req_failed", "rate", 0)),
        "http_avg_ms": metric(data, "http_req_duration", "avg"),
        "http_p5_ms": metric(data, "http_req_duration", "p(5)"),
        "http_p50_ms": metric(data, "http_req_duration", "med"),
        "http_p90_ms": metric(data, "http_req_duration", "p(90)"),
        "http_p95_ms": metric(data, "http_req_duration", "p(95)"),
        "http_p99_ms": metric(data, "http_req_duration", "p(99)"),
        "http_max_ms": metric(data, "http_req_duration", "max"),
        "app_avg_ms": metric(data, "app_processing_ms", "avg"),
        "app_p95_ms": metric(data, "app_processing_ms", "p(95)"),
        "infrastructure_avg_ms": metric(data, "infrastructure_overhead_ms", "avg"),
        "infrastructure_p95_ms": metric(data, "infrastructure_overhead_ms", "p(95)"),
        "policy_allowed_reqs": metric(data, "policy_allowed_requests", "count"),
        "policy_blocked_reqs": metric(data, "policy_blocked_requests", "count"),
        "policy_allowed_expected_pct": percent(
            metric(data, "policy_allowed_expected_rate", "rate")
        ),
        "policy_blocked_expected_pct": percent(
            metric(data, "policy_blocked_expected_rate", "rate")
        ),
        "policy_allowed_p50_ms": metric(data, "policy_allowed_duration_ms", "med"),
        "policy_allowed_p95_ms": metric(data, "policy_allowed_duration_ms", "p(95)"),
        "policy_blocked_p50_ms": metric(data, "policy_blocked_duration_ms", "med"),
        "policy_blocked_p95_ms": metric(data, "policy_blocked_duration_ms", "p(95)"),
        "policy_allowed_connect_p50_ms": metric(
            data, "policy_allowed_connecting_ms", "med"
        ),
        "policy_allowed_connect_p95_ms": metric(
            data, "policy_allowed_connecting_ms", "p(95)"
        ),
        "policy_blocked_connect_p50_ms": metric(
            data, "policy_blocked_connecting_ms", "med"
        ),
        "policy_blocked_connect_p95_ms": metric(
            data, "policy_blocked_connecting_ms", "p(95)"
        ),
        "target_url": diploma.get("targetUrl", ""),
        "request_method": diploma.get("requestMethod", ""),
        "request_path": diploma.get("requestPath", ""),
        "blocked_target_url": diploma.get("blockedTargetUrl", ""),
        "blocked_method": diploma.get("blockedMethod", ""),
        "blocked_path": diploma.get("blockedPath", ""),
        "payload_size": diploma.get("payloadSize", ""),
        "response_size": diploma.get("responseSize", ""),
        "server_delay_ms": diploma.get("serverDelayMs", ""),
    }

    append_row(Path(args.csv), row)


if __name__ == "__main__":
    main()
