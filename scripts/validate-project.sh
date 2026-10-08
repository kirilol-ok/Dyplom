#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "${ROOT_DIR}/scripts" -maxdepth 1 -name '*.sh' -print0 | while IFS= read -r -d '' file; do
  bash -n "${file}"
done

python3 - "${ROOT_DIR}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in root.joinpath("scripts").glob("*.py"):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

for file in "${ROOT_DIR}"/k6/*.js; do
  node --check "${file}" >/dev/null
done

required_files=(
  "${ROOT_DIR}/k6/l4-attack.js"
  "${ROOT_DIR}/k6/l7-spaghetti.js"
  "${ROOT_DIR}/k8s/policies/calico-l7-spaghetti.yaml"
  "${ROOT_DIR}/k8s/policies/istio-ambient-l7-spaghetti.yaml"
)

for file in "${required_files[@]}"; do
  [[ -f "${file}" ]] || { echo "Missing required file: ${file}" >&2; exit 1; }
done

if grep -E 'RESULT_DIR=|k6-raw\.json|resource-summary\.csv' \
  "${ROOT_DIR}/scripts/run-k6.sh" "${ROOT_DIR}/k8s/k6-job.yaml.tmpl"; then
  echo "Per-run result persistence is still enabled" >&2
  exit 1
fi

echo "Static validation passed"
