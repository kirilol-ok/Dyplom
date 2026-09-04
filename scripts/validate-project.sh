#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "${ROOT_DIR}/scripts" -maxdepth 1 -name '*.sh' -print0 | while IFS= read -r -d '' file; do
  bash -n "${file}"
done

python3 -m py_compile "${ROOT_DIR}"/scripts/*.py

for file in "${ROOT_DIR}"/k6/*.js; do
  node --check "${file}" >/dev/null
done

if grep -R --line-number --include='*.sh' --include='*.js' --include='*.py' \
  --exclude='validate-project.sh' -E 'saturation|concurrency-vus|run-until-fail' "${ROOT_DIR}/scripts" "${ROOT_DIR}/k6"; then
  echo "Unexpected legacy benchmark scenario found" >&2
  exit 1
fi

echo "Static validation passed"
