#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS="${APP_NS:-test-app}"
EXPECTED_CONTEXT="${AMBIENT_CONTEXT:-k3d-istio-ambient-l4}"
POLICY_FILE="${ROOT_DIR}/k8s/policies/calico-ambient-health-probes.yaml"

current_context="$(kubectl config current-context 2>/dev/null || true)"

if [[ "${current_context}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "[ERROR] Refusing to apply Ambient-only policy." >&2
  echo "[ERROR] Current context: ${current_context:-<none>}" >&2
  echo "[ERROR] Expected context: ${EXPECTED_CONTEXT}" >&2
  exit 1
fi

if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "[ERROR] Policy file not found: ${POLICY_FILE}" >&2
  exit 1
fi

echo "[INFO] Applying Ambient health-probe policy in namespace ${APP_NS}"

sed "s|__APP_NS__|${APP_NS}|g" "${POLICY_FILE}" \
  | kubectl apply -f -

echo "[INFO] Waiting for deployment/server to become Available"

kubectl wait \
  --for=condition=Available \
  deployment/server \
  -n "${APP_NS}" \
  --timeout=180s

echo "[INFO] Ambient health-probe policy is active"

kubectl get networkpolicy.projectcalico.org \
  server-allow-ambient-health-probes \
  -n "${APP_NS}" \
  -o wide
