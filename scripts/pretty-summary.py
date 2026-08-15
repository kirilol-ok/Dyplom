#!/usr/bin/env python3
import argparse
import csv
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def metric(data, name, key, default=""):
    value = data.get("metrics", {}).get(name, {}).get("values", {}).get(key)
    return default if value is None else value


def percent(value):
    if value in (None, ""):
        return ""
    return round(float(value) * 100.0, 6)


def append_csv_with_schema_migration(csv_path: Path, row: dict):
    """Append a row while preserving older CSVs when new columns are added.

    Previous versions aborted on any header change. That made adding a metric
    require deleting/archiving the whole CSV. We now preserve every existing
    column and append any newly introduced columns, filling historical rows
    with empty values for fields that did not exist at the time.
    """
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    new_fields = list(row.keys())

    if not csv_path.exists() or csv_path.stat().st_size == 0:
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=new_fields)
            writer.writeheader()
            writer.writerow(row)
        return

    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        old_fields = reader.fieldnames or []
        old_rows = list(reader)

    merged_fields = old_fields + [field for field in new_fields if field not in old_fields]

    if merged_fields != old_fields:
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{csv_path.name}.", suffix=".tmp", dir=str(csv_path.parent)
        )
        os.close(fd)
        tmp_path = Path(tmp_name)
        try:
            with tmp_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=merged_fields, extrasaction="ignore")
                writer.writeheader()
                for old_row in old_rows:
                    writer.writerow(old_row)
            os.replace(tmp_path, csv_path)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()

    with csv_path.open("a", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=merged_fields, extrasaction="ignore")
        writer.writerow(row)


def load_optional_json(path_value):
    """Load an optional JSON file.

    A missing or malformed cgroup report must not invalidate an otherwise
    successful k6 benchmark. In that case resource columns remain empty.
    """
    if not path_value:
        return None

    path = Path(path_value)
    if not path.is_file():
        print(f"warning: cgroup JSON not found: {path}", file=os.sys.stderr)
        return None

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: cannot read cgroup JSON {path}: {exc}", file=os.sys.stderr)
        return None


def _number(value):
    if value in (None, "") or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _lookup(mapping, names):
    if not isinstance(mapping, dict):
        return None

    for name in names:
        if name in mapping:
            value = _number(mapping[name])
            if value is not None:
                return value
    return None


def _role_scope(data, role):
    """Find a role-specific cgroup object in a few compatible layouts."""
    if not isinstance(data, dict):
        return None

    direct = data.get(role)
    if isinstance(direct, dict):
        return direct

    for parent_name in ("containers", "cgroups", "cpu", "workloads", "pods"):
        parent = data.get(parent_name)
        if isinstance(parent, dict):
            candidate = parent.get(role)
            if isinstance(candidate, dict):
                return candidate

    return None


def _delta_from_scope(scope, field_aliases):
    """Extract a counter delta, preferring an explicit delta object.

    Supported report layouts include:
      role.delta.<counter>
      role.cpu.delta.<counter>
      role.initial/final.<counter>
      role.before/after.<counter>
      role.start/end.<counter>
    """
    if not isinstance(scope, dict):
        return None

    delta_candidates = [
        scope.get("delta"),
        scope.get("cpu_delta"),
        scope.get("cpuDelta"),
    ]

    cpu_obj = scope.get("cpu")
    if isinstance(cpu_obj, dict):
        delta_candidates.extend(
            [
                cpu_obj.get("delta"),
                cpu_obj.get("cpu_delta"),
                cpu_obj.get("cpuDelta"),
            ]
        )

    for candidate in delta_candidates:
        value = _lookup(candidate, field_aliases)
        if value is not None:
            return value

    start_candidates = [
        scope.get("initial"),
        scope.get("before"),
        scope.get("start"),
    ]
    end_candidates = [
        scope.get("final"),
        scope.get("after"),
        scope.get("end"),
    ]

    if isinstance(cpu_obj, dict):
        start_candidates.extend(
            [
                cpu_obj.get("initial"),
                cpu_obj.get("before"),
                cpu_obj.get("start"),
            ]
        )
        end_candidates.extend(
            [
                cpu_obj.get("final"),
                cpu_obj.get("after"),
                cpu_obj.get("end"),
            ]
        )

    for start_obj in start_candidates:
        start_value = _lookup(start_obj, field_aliases)
        if start_value is None:
            continue

        for end_obj in end_candidates:
            end_value = _lookup(end_obj, field_aliases)
            if end_value is not None:
                return end_value - start_value

    return None


def _flat_delta(data, role, counter_aliases):
    """Fallback for reports that store role/counter deltas as flat keys."""
    if not isinstance(data, dict):
        return None

    normalized = {
        str(key).lower().replace("-", "_"): value
        for key, value in data.items()
    }

    for counter in counter_aliases:
        counter_norm = counter.lower().replace("-", "_")
        candidates = (
            f"{role}_{counter_norm}_delta",
            f"{role}_cpu_{counter_norm}_delta",
            f"{role}_{counter_norm}_delta_usec",
        )
        for key in candidates:
            if key in normalized:
                value = _number(normalized[key])
                if value is not None:
                    return value

    return None


def cgroup_cpu_fields(cgroup_data, role):
    """Return flattened per-run CPU/cgroup metrics for one benchmark role."""
    empty = {
        f"{role}_cpu_usage_delta_s": "",
        f"{role}_cpu_nr_periods_delta": "",
        f"{role}_cpu_nr_throttled_delta": "",
        f"{role}_cpu_throttled_period_pct": "",
        f"{role}_cpu_throttled_time_ms": "",
    }

    if not isinstance(cgroup_data, dict):
        return empty

    scope = _role_scope(cgroup_data, role)

    aliases = {
        "usage_usec": ("usage_usec", "usageUsec", "usage_us", "usageUs"),
        "nr_periods": ("nr_periods", "nrPeriods"),
        "nr_throttled": ("nr_throttled", "nrThrottled"),
        "throttled_usec": (
            "throttled_usec",
            "throttledUsec",
            "throttled_us",
            "throttledUs",
        ),
    }

    deltas = {}
    for counter, counter_aliases in aliases.items():
        value = _delta_from_scope(scope, counter_aliases)
        if value is None:
            value = _flat_delta(cgroup_data, role, counter_aliases)
        deltas[counter] = value

    usage_usec = deltas["usage_usec"]
    nr_periods = deltas["nr_periods"]
    nr_throttled = deltas["nr_throttled"]
    throttled_usec = deltas["throttled_usec"]

    throttled_period_pct = ""
    if nr_periods is not None and nr_periods > 0 and nr_throttled is not None:
        throttled_period_pct = round(100.0 * nr_throttled / nr_periods, 6)

    return {
        f"{role}_cpu_usage_delta_s": ""
        if usage_usec is None
        else round(usage_usec / 1_000_000.0, 6),
        f"{role}_cpu_nr_periods_delta": ""
        if nr_periods is None
        else int(nr_periods),
        f"{role}_cpu_nr_throttled_delta": ""
        if nr_throttled is None
        else int(nr_throttled),
        f"{role}_cpu_throttled_period_pct": throttled_period_pct,
        f"{role}_cpu_throttled_time_ms": ""
        if throttled_usec is None
        else round(throttled_usec / 1_000.0, 6),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("summary")
    parser.add_argument("--csv")
    parser.add_argument("--run-tag", default="")
    parser.add_argument("--run-index", default="1")
    parser.add_argument("--script", default="")
    parser.add_argument(
        "--cgroup-json",
        default="",
        help="Optional per-run cgroup CPU report JSON",
    )
    args = parser.parse_args()

    path = Path(args.summary)
    data = json.loads(path.read_text(encoding="utf-8"))
    diploma = data.get("diploma", {})
    state = data.get("state", {})
    cgroup_data = load_optional_json(args.cgroup_json)

    reqs = float(metric(data, "http_reqs", "count", 0) or 0)
    dropped = float(metric(data, "dropped_iterations", "count", 0) or 0)
    scheduled = reqs + dropped
    target_delivery = 100.0 if scheduled == 0 else 100.0 * reqs / scheduled

    expected_rate = metric(data, "expected_status_rate", "rate", "")
    if expected_rate == "":
        failed = metric(data, "http_req_failed", "rate", "")
        expected_rate = "" if failed == "" else 1.0 - float(failed)
    successful_target = "" if expected_rate == "" else target_delivery * float(expected_rate)

    run_duration_ms = state.get("testRunDurationMs", "")
    run_duration_s = "" if run_duration_ms == "" else round(float(run_duration_ms) / 1000.0, 6)

    # `vus` is the built-in Gauge for the number of active VUs. Its `max`
    # value is the metric we actually need when sizing preAllocatedVUs.
    active_vus_min = metric(data, "vus", "min")
    active_vus_max = metric(data, "vus", "max")
    active_vus_final = metric(data, "vus", "value")
    possible_vus_max = metric(data, "vus_max", "max")

    k6_cgroup = cgroup_cpu_fields(cgroup_data, "k6")
    server_cgroup = cgroup_cpu_fields(cgroup_data, "server")

    print(f"model:              {diploma.get('model', '-')}")
    print(f"profile:            {diploma.get('profile', '-')}")
    print(f"requests:           {int(reqs)}")
    print(f"dropped iterations: {int(dropped)}")
    print(f"target delivery:    {target_delivery:.2f}%")
    if expected_rate != "":
        print(f"expected status:    {100.0 * float(expected_rate):.2f}%")
        print(f"successful target:  {float(successful_target):.2f}%")
    print(f"active VUs peak:    {active_vus_max if active_vus_max != '' else '-'}")
    print(f"VU capacity max:    {possible_vus_max if possible_vus_max != '' else '-'}")
    print(f"latency p95:        {metric(data, 'http_req_duration', 'p(95)', '-')} ms")
    print(f"latency p99:        {metric(data, 'http_req_duration', 'p(99)', '-')} ms")
    print(f"app p95:            {metric(data, 'app_processing_ms', 'p(95)', '-')} ms")
    print(f"infra p95:          {metric(data, 'infrastructure_overhead_ms', 'p(95)', '-')} ms")

    if cgroup_data is not None:
        print(
            "k6 CPU usage:       "
            f"{k6_cgroup['k6_cpu_usage_delta_s'] if k6_cgroup['k6_cpu_usage_delta_s'] != '' else '-'} s"
        )
        print(
            "server CPU usage:   "
            f"{server_cgroup['server_cpu_usage_delta_s'] if server_cgroup['server_cpu_usage_delta_s'] != '' else '-'} s"
        )

    if not args.csv:
        return

    row = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "model": diploma.get("model", ""),
        "profile": diploma.get("profile", Path(args.script).stem),
        "script": args.script,
        "run_tag": args.run_tag,
        "run_index": args.run_index,
        "target_url": diploma.get("targetUrl", ""),
        "test_mode": diploma.get("testMode", ""),
        "configured_rps": diploma.get("rps", ""),
        "achieved_rps": metric(data, "http_reqs", "rate"),
        "configured_vus": diploma.get("vus", ""),
        "configured_max_vus": diploma.get("maxVUs", ""),
        "vus_active_min": active_vus_min,
        "vus_active_max": active_vus_max,
        "vus_active_final": active_vus_final,
        # Kept for backwards compatibility. This is *capacity*, not active VUs.
        "vus_max": possible_vus_max,
        "configured_duration": diploma.get("duration", ""),
        "run_duration_s": run_duration_s,
        "http_reqs": int(reqs),
        "dropped_iterations": int(dropped),
        "scheduled_iterations": int(scheduled),
        "target_delivery_pct": round(target_delivery, 6),
        "expected_status_pct": percent(expected_rate),
        "successful_target_pct": "" if successful_target == "" else round(float(successful_target), 6),
        "http_failed_pct": percent(metric(data, "http_req_failed", "rate")),
        "checks_pct": percent(metric(data, "checks", "rate")),
        "http_avg_ms": metric(data, "http_req_duration", "avg"),
        "http_p50_ms": metric(data, "http_req_duration", "med"),
        "http_p90_ms": metric(data, "http_req_duration", "p(90)"),
        "http_p95_ms": metric(data, "http_req_duration", "p(95)"),
        "http_p99_ms": metric(data, "http_req_duration", "p(99)"),
        "http_max_ms": metric(data, "http_req_duration", "max"),
        "app_avg_ms": metric(data, "app_processing_ms", "avg"),
        "app_p95_ms": metric(data, "app_processing_ms", "p(95)"),
        "infrastructure_avg_ms": metric(data, "infrastructure_overhead_ms", "avg"),
        "infrastructure_p95_ms": metric(data, "infrastructure_overhead_ms", "p(95)"),
        "request_method": diploma.get("requestMethod", ""),
        "request_path": diploma.get("requestPath", ""),
        "payload_size": diploma.get("payloadSize", ""),
        "response_size": diploma.get("responseSize", ""),
        "server_delay_ms": diploma.get("serverDelayMs", ""),
        "no_connection_reuse": diploma.get("noConnectionReuse", ""),
    }

    row.update(k6_cgroup)
    row.update(server_cgroup)

    append_csv_with_schema_migration(Path(args.csv), row)


if __name__ == "__main__":
    main()
