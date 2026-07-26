#!/usr/bin/env bash
set -euo pipefail

APP_NS="${APP_NS:-test-app}"
POLICY_FILE="${1:-k8s/policies/calico-l4-client-to-server.yaml}"

if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "[ERROR] Policy file not found: ${POLICY_FILE}" >&2
  exit 1
fi

echo "[INFO] Applying ${POLICY_FILE} to namespace ${APP_NS}"
sed "s|__APP_NS__|${APP_NS}|g" "${POLICY_FILE}" | kubectl apply -f -

echo "[INFO] Removing obsolete duplicate k6-only policy, if present"
kubectl delete networkpolicy.projectcalico.org \
  server-l4-allow-k6-direct \
  -n "${APP_NS}" \
  --ignore-not-found=true

echo "[INFO] Removing current k6 Job so the next run uses the updated Pod labels"
kubectl delete job k6-test \
  -n "${APP_NS}" \
  --ignore-not-found=true \
  --cascade=foreground \
  --wait=true

echo "[INFO] Active server policies:"
kubectl get networkpolicy.projectcalico.org -n "${APP_NS}"

echo "[INFO] Fix applied"
