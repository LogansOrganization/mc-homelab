#!/usr/bin/env bash
set -euo pipefail

# SERVER_NAME - the name used when the server was deployed

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')
NAMESPACE="mc-${SERVER_NAME}"

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: No server named '${SERVER_NAME}' found (namespace ${NAMESPACE} does not exist)."
  exit 1
fi

# Grab the PV name before we delete anything, so we can tell the user where their world lives
PVC_UID=$(kubectl get pvc world-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)

echo "== Tearing down server: ${SERVER_NAME} =="
kubectl delete namespace "$NAMESPACE" --timeout=120s

echo ""
echo "=================================================="
echo " Server '${SERVER_NAME}' has been removed."
if [ -n "$PVC_UID" ]; then
  echo " World data is preserved (Longhorn Retain policy)."
  echo " Underlying volume: ${PVC_UID}"
  echo " It will show as 'Released' in 'kubectl get pv' or the Longhorn UI."
  echo " Redeploying a server with the SAME name will get a fresh volume, not this one -"
  echo " to reuse this exact world, you'd need to manually bind a new PVC to this PV."
else
  echo " (Could not determine the world's volume name - check 'kubectl get pv' manually.)"
fi
echo "=================================================="
