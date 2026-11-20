#!/usr/bin/env python3
"""Fingerprint the effective benchmark container resources before each run.

The full normalized configuration is stored once per distinct config_id.
"""
import argparse
import hashlib
import json
import subprocess
from collections import Counter
from pathlib import Path


def command(argv, required=True):
    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode and required:
        raise RuntimeError(f"{' '.join(argv)}: {result.stderr.strip()}")
    return result.stdout.strip() if result.returncode == 0 else ""


def kjson(*args):
    return json.loads(command(["kubectl", *args]))


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
    if ns in ("calico-system", "tigera-operator") or p.startswith(("calico-", "tigera-")):
        return "calico-control"
    if p.startswith("server-") and c == "server":
        return "app-server"
    if p.startswith("client-") and c == "client":
        return "app-client"
    if p.startswith("k6-") and c == "k6":
        return "load-generator"
    return "other"


def cluster_containers(pods, job_name):
    container_counts = Counter()
    representative = {}
    for pod in pods.get("items", []):
        meta = pod.get("metadata", {})
        namespace = meta.get("namespace", "")
        labels = meta.get("labels", {})
        if meta.get("deletionTimestamp") or pod.get("status", {}).get("phase") in ("Failed", "Succeeded"):
            continue
        spec = pod.get("spec", {})
        # Native sidecars are initContainers with restartPolicy=Always. They keep
        # running throughout the test and must be included in expected counts.
        running_containers = list(spec.get("containers", []))
        running_containers.extend(
            c for c in spec.get("initContainers", [])
            if c.get("restartPolicy") == "Always"
        )
        status_by_name = {
            s.get("name"): s.get("imageID", "")
            for s in (pod.get("status", {}).get("containerStatuses", [])
                      + pod.get("status", {}).get("initContainerStatuses", []))
        }
        for container in running_containers:
            if container.get("name") == "k6" and labels.get("job-name") != job_name:
                continue
            entry = {
                "namespace": namespace,
                "role": labels.get("benchmark-role", ""),
                "group": classify(namespace, meta.get("name", ""), container.get("name", "")),
                "container": container.get("name", ""),
                "image": container.get("image", ""),
                "image_id": status_by_name.get(container.get("name"), ""),
                "requests": container.get("resources", {}).get("requests", {}),
                "limits": container.get("resources", {}).get("limits", {}),
            }
            canonical = json.dumps(entry, sort_keys=True, separators=(",", ":"))
            container_counts[canonical] += 1
            representative[canonical] = entry
    return [dict(representative[k], replicas=container_counts[k]) for k in sorted(container_counts)]


def selected(containers, namespace, name):
    matches = [c for c in containers if c["namespace"] == namespace and c["container"] == name]
    if not matches:
        raise RuntimeError(f"Container {namespace}/{name} was not found in live pods")
    if len(matches) != 1 or matches[0]["replicas"] != 1:
        raise RuntimeError(f"Expected one {namespace}/{name} container, found {matches}")
    return matches[0]


def pod_node(pods, namespace, container_name, pod_name=""):
    matches = []
    for pod in pods.get("items", []):
        meta = pod.get("metadata", {})
        if meta.get("namespace") != namespace or meta.get("deletionTimestamp"):
            continue
        if pod_name and meta.get("name") != pod_name:
            continue
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        if any(c.get("name") == container_name for c in pod.get("spec", {}).get("containers", [])):
            matches.append(pod)
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one pod with container {namespace}/{container_name}: found {len(matches)}")
    node = matches[0].get("spec", {}).get("nodeName", "")
    if not node:
        raise RuntimeError(f"Pod {matches[0]['metadata']['name']} is not assigned to a node")
    return node


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--archive-dir", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--namespace", default="test-app")
    parser.add_argument("--script", required=True, help="Path to the executed k6 script")
    parser.add_argument("--job-name", required=True)
    parser.add_argument("--k6-pod", required=True)
    args = parser.parse_args()

    pods = kjson("get", "pods", "-A", "-o", "json")
    nodes = kjson("get", "nodes", "-o", "json")
    containers = cluster_containers(pods, args.job_name)
    server = selected(containers, args.namespace, "server")
    loadgen = selected(containers, args.namespace, "k6")
    server_node = pod_node(pods, args.namespace, "server")
    client_node = pod_node(pods, args.namespace, "client")
    k6_node = pod_node(pods, args.namespace, "k6", args.k6_pod)
    # Stop a benchmark if traffic topology differs from the intended setup.
    if client_node == server_node:
        raise RuntimeError(f"Client and server are on the same node: {server_node}")
    if k6_node == server_node:
        raise RuntimeError(f"k6 and server are on the same node: {server_node}")

    kube_nodes = sorted([
        {
            "kubelet_version": n.get("status", {}).get("nodeInfo", {}).get("kubeletVersion", ""),
            "allocatable_cpu": n.get("status", {}).get("allocatable", {}).get("cpu", ""),
            "allocatable_memory": n.get("status", {}).get("allocatable", {}).get("memory", ""),
        }
        for n in nodes.get("items", [])
    ], key=lambda x: json.dumps(x, sort_keys=True))

    root = Path(args.repo_root)
    revision = command(["git", "-C", str(root), "rev-parse", "HEAD"], required=False)
    docker_info = command([
        "docker", "info", "--format", "{{.NCPU}} {{.MemTotal}}"
    ], required=False)
    script_sha = hashlib.sha256(Path(args.script).read_bytes()).hexdigest()

    config = {
        "schema_version": 1,
        "git_revision": revision,
        "docker_cpu_and_memory_bytes": docker_info,
        "nodes": kube_nodes,
        "k6_script_sha256": script_sha,
        "containers": containers,
    }
    # Excludes run-specific pod names, Job names, RPS and VU counts.
    serialized = json.dumps(config, sort_keys=True, separators=(",", ":"))
    config_id = hashlib.sha256(serialized.encode("utf-8")).hexdigest()[:16]
    metadata = {
        "config_id": config_id,
        "k6_pod_name": args.k6_pod,
        "k6_node": k6_node,
        "server_node": server_node,
        "client_node": client_node,
        "git_revision": revision,
        "server_cpu_request": server["requests"].get("cpu", ""),
        "server_cpu_limit": server["limits"].get("cpu", "unlimited"),
        "server_memory_limit": server["limits"].get("memory", "unlimited"),
        "k6_cpu_limit": loadgen["limits"].get("cpu", "unlimited"),
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    archive = Path(args.archive_dir)
    archive.mkdir(parents=True, exist_ok=True)
    destination = archive / f"{config_id}.json"
    if not destination.exists():
        destination.write_text(json.dumps({"config_id": config_id, **config}, indent=2) + "\n", encoding="utf-8")
    print(f"config_id={config_id}, server_cpu_limit={metadata['server_cpu_limit']}, k6_cpu_limit={metadata['k6_cpu_limit']}")


if __name__ == "__main__":
    main()
