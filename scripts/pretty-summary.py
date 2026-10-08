#!/usr/bin/env python3
import argparse
import json


def metric(data, name, key, default=0):
    return data.get("metrics", {}).get(name, {}).get("values", {}).get(key, default)


def has_metric(data, name):
    return name in data.get("metrics", {})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("summary")
    args = parser.parse_args()

    with open(args.summary, encoding="utf-8") as handle:
        data = json.load(handle)

    d = data.get("diploma", {})
    rows = [
        ("Model", d.get("model", "")),
        ("Profile", d.get("profile", "")),
        ("Mode", d.get("testMode", "")),
        ("Variant", d.get("scenarioVariant", "")),
        ("Configured RPS", d.get("rps", "")),
        ("Achieved RPS", f"{float(metric(data, 'http_reqs', 'rate')):.2f}"),
        ("Requests", int(metric(data, "http_reqs", "count"))),
        ("Dropped iterations", int(metric(data, "dropped_iterations", "count", 0))),
        ("HTTP p5", f"{float(metric(data, 'http_req_duration', 'p(5)')):.2f} ms"),
        ("HTTP median", f"{float(metric(data, 'http_req_duration', 'med')):.2f} ms"),
        ("HTTP p95", f"{float(metric(data, 'http_req_duration', 'p(95)')):.2f} ms"),
        ("HTTP p99", f"{float(metric(data, 'http_req_duration', 'p(99)')):.2f} ms"),
        ("Expected status", f"{float(metric(data, 'expected_status_rate', 'rate', 1)) * 100:.2f}%"),
        ("HTTP failed", f"{float(metric(data, 'http_req_failed', 'rate', 0)) * 100:.2f}%"),
    ]

    if has_metric(data, "policy_allowed_requests"):
        rows.extend([
            ("Allowed target RPS", d.get("allowedRps", "")),
            ("Blocked target RPS", d.get("blockedRps", "")),
            ("Allowed requests", int(metric(data, "policy_allowed_requests", "count"))),
            ("Blocked requests", int(metric(data, "policy_blocked_requests", "count"))),
            (
                "Allowed expected",
                f"{float(metric(data, 'policy_allowed_expected_rate', 'rate')) * 100:.2f}%",
            ),
            (
                "Blocked expected",
                f"{float(metric(data, 'policy_blocked_expected_rate', 'rate')) * 100:.2f}%",
            ),
            (
                "Allowed median",
                f"{float(metric(data, 'policy_allowed_duration_ms', 'med')):.2f} ms",
            ),
            (
                "Blocked median",
                f"{float(metric(data, 'policy_blocked_duration_ms', 'med')):.2f} ms",
            ),
            (
                "Allowed connect median",
                f"{float(metric(data, 'policy_allowed_connecting_ms', 'med')):.2f} ms",
            ),
            (
                "Blocked connect median",
                f"{float(metric(data, 'policy_blocked_connecting_ms', 'med')):.2f} ms",
            ),
        ])

    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        print(f"{label:<{width}} : {value}")


if __name__ == "__main__":
    main()
