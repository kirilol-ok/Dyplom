#!/usr/bin/env python3
import json
import sys
from pathlib import Path
from typing import Any


def pick_latest_summary(results_dir: Path) -> Path | None:
    files = sorted(results_dir.rglob("*-summary.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def load_summary(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def metric(data: dict[str, Any], name: str, key: str) -> Any:
    return data.get("metrics", {}).get(name, {}).get("values", {}).get(key)


def meta(data: dict[str, Any], key: str) -> Any:
    return data.get("diploma", {}).get(key)


def option(data: dict[str, Any], key: str) -> Any:
    return data.get("options", {}).get(key)


def state(data: dict[str, Any], key: str) -> Any:
    return data.get("state", {}).get(key)


def fmt_int(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return str(int(round(float(value))))
    except (TypeError, ValueError):
        return str(value)


def fmt_float(value: Any, digits: int = 2) -> str:
    if value is None:
        return "-"
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return str(value)


def fmt_pct(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return f"{float(value) * 100:.2f}%"
    except (TypeError, ValueError):
        return str(value)


def fmt_ms(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return f"{float(value):.2f} ms"
    except (TypeError, ValueError):
        return str(value)


def fmt_sec_from_ms(value: Any) -> str:
    if value is None:
        return "-"
    try:
        return f"{float(value) / 1000:.2f} s"
    except (TypeError, ValueError):
        return str(value)


def build_table(rows: list[tuple[str, str]]) -> str:
    left_width = max(len(k) for k, _ in rows)
    right_width = max(len(v) for _, v in rows)
    top = f"┌{'─' * (left_width + 2)}┬{'─' * (right_width + 2)}┐"
    mid = f"├{'─' * (left_width + 2)}┼{'─' * (right_width + 2)}┤"
    bot = f"└{'─' * (left_width + 2)}┴{'─' * (right_width + 2)}┘"
    out = [top]
    for idx, (key, value) in enumerate(rows):
        out.append(f"│ {key.ljust(left_width)} │ {value.ljust(right_width)} │")
        if idx != len(rows) - 1:
            out.append(mid)
    out.append(bot)
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) > 1:
        summary_path = Path(sys.argv[1])
    else:
        summary_path = pick_latest_summary(Path("results"))
        if summary_path is None:
            print("No summary file found in ./results", file=sys.stderr)
            return 1

    if not summary_path.exists():
        print(f"Summary file not found: {summary_path}", file=sys.stderr)
        return 1

    data = load_summary(summary_path)
    vus = meta(data, "vus") or option(data, "vus") or metric(data, "vus_max", "value")
    duration = meta(data, "duration") or fmt_sec_from_ms(state(data, "testRunDurationMs"))

    rows = [
        ("File", summary_path.name),
        ("Model", str(meta(data, "model") or "-")),
        ("Mode", str(meta(data, "testMode") or "-")),
        ("Target", str(meta(data, "targetUrl") or "-")),
        ("VUs", fmt_int(vus)),
        ("Configured duration", str(duration)),
        ("Actual duration", fmt_sec_from_ms(state(data, "testRunDurationMs"))),
        ("HTTP requests", fmt_int(metric(data, "http_reqs", "count"))),
        ("HTTP req/s", fmt_float(metric(data, "http_reqs", "rate"))),
        ("Iterations", fmt_int(metric(data, "iterations", "count"))),
        ("Iter/s", fmt_float(metric(data, "iterations", "rate"))),
        ("HTTP fail rate", fmt_pct(metric(data, "http_req_failed", "rate"))),
        ("Expected success", fmt_pct(metric(data, "success_rate", "rate"))),
        ("Blocked as expected", fmt_pct(metric(data, "blocked_expected_rate", "rate"))),
        ("HTTP avg", fmt_ms(metric(data, "http_req_duration", "avg"))),
        ("HTTP p90", fmt_ms(metric(data, "http_req_duration", "p(90)"))),
        ("HTTP p95", fmt_ms(metric(data, "http_req_duration", "p(95)"))),
        ("HTTP p99", fmt_ms(metric(data, "http_req_duration", "p(99)"))),
        ("HTTP max", fmt_ms(metric(data, "http_req_duration", "max"))),
        ("Upstream avg", fmt_ms(metric(data, "upstream_latency_ms", "avg"))),
        ("Upstream p95", fmt_ms(metric(data, "upstream_latency_ms", "p(95)"))),
        ("Data received", fmt_float(metric(data, "data_received", "count"))),
        ("Data sent", fmt_float(metric(data, "data_sent", "count"))),
    ]

    print()
    print(build_table(rows))
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
