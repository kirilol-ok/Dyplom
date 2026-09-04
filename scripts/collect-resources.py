#!/usr/bin/env python3
import argparse
import csv
import re
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

RUNNING = True


def stop_handler(_signum, _frame):
    global RUNNING
    RUNNING = False


def run(command):
    return subprocess.run(command, capture_output=True, text=True, check=False)


def cpu_to_mcores(value):
    value = value.strip()
    if not value:
        return 0.0
    match = re.fullmatch(r"([0-9.]+)([num]?)", value)
    if not match:
        return 0.0
    number = float(match.group(1))
    suffix = match.group(2)
    if suffix == "n":
        return number / 1_000_000.0
    if suffix == "u":
        return number / 1_000.0
    if suffix == "m":
        return number
    return number * 1000.0


def memory_to_mib(value):
    value = value.strip()
    match = re.fullmatch(r"([0-9.]+)([KMGTE]i|[kMGTPE]?B)?", value)
    if not match:
        return 0.0
    number = float(match.group(1))
    suffix = match.group(2) or ""
    factors = {
        "Ki": 1 / 1024,
        "Mi": 1,
        "Gi": 1024,
        "Ti": 1024 * 1024,
        "K": 1 / 1024,
        "M": 1,
        "G": 1024,
        "KB": 1000 / (1024 * 1024),
        "MB": 1_000_000 / (1024 * 1024),
        "GB": 1_000_000_000 / (1024 * 1024),
        "": 1 / (1024 * 1024),
    }
    return number * factors.get(suffix, 0)


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def collect_pods(writer):
    result = run(["kubectl", "top", "pod", "-A", "--containers", "--no-headers"])
    if result.returncode != 0:
        return False

    ts = timestamp()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        namespace, pod, container, cpu, memory = fields[:5]
        writer.writerow({
            "timestamp_utc": ts,
            "scope": "container",
            "namespace": namespace,
            "pod": pod,
            "container": container,
            "node": "",
            "cpu_mcores": round(cpu_to_mcores(cpu), 6),
            "memory_mib": round(memory_to_mib(memory), 6),
        })
    return True


def collect_nodes(writer):
    result = run(["kubectl", "top", "nodes", "--no-headers"])
    if result.returncode != 0:
        return False

    ts = timestamp()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        node, cpu, _cpu_pct, memory, _memory_pct = fields[:5]
        writer.writerow({
            "timestamp_utc": ts,
            "scope": "node",
            "namespace": "",
            "pod": "",
            "container": "",
            "node": node,
            "cpu_mcores": round(cpu_to_mcores(cpu), 6),
            "memory_mib": round(memory_to_mib(memory), 6),
        })
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "timestamp_utc", "scope", "namespace", "pod", "container", "node",
        "cpu_mcores", "memory_mib",
    ]

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        handle.flush()

        while RUNNING:
            collect_pods(writer)
            collect_nodes(writer)
            handle.flush()
            deadline = time.monotonic() + max(args.interval, 0.2)
            while RUNNING and time.monotonic() < deadline:
                time.sleep(min(0.2, deadline - time.monotonic()))


if __name__ == "__main__":
    main()
