#!/usr/bin/env bash
# Tears down one Minecraft server: closes its router port, deletes its namespace.
# The world is kept (longhorn-retain) unless DELETE_WORLD=true. Deploying the same name again
# brings the kept world back.
#
# Inputs (env): SERVER_NAME, DELETE_WORLD (true|false)
set -euo pipefail

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
DELETE_WORLD="${DELETE_WORLD:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
NAMESPACE="mc-${SERVER_NAME}"

PV=$(kubectl get pv -l "mc-world=${SERVER_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  [ "$DELETE_WORLD" = true ] && [ -n "$PV" ] || { echo "ERROR: no server named '${SERVER_NAME}'." >&2; exit 1; }
  echo "Server '${SERVER_NAME}' isn't running; only deleting its kept world."
fi

echo "== Tearing down '${SERVER_NAME}' =="
homelab-port close "$NAMESPACE" || echo "::warning::Couldn't close the router port for ${NAMESPACE}; check homelab-port list."
homelab-dns delete "$NAMESPACE" || echo "::warning::Couldn't remove the DNS name for ${NAMESPACE}; check homelab-dns list."
kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=180s

WORLD_LINE="kept. Deploy the name '${SERVER_NAME}' again to get it back"
if [ "$DELETE_WORLD" = true ] && [ -n "$PV" ]; then
  # The PV is Released and kept (Retain). Switching it to Delete makes Kubernetes remove it and
  # its Longhorn volume, freeing the disk space.
  kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
  kubectl wait --for=delete "pv/$PV" --timeout=120s || echo "::warning::World volume ${PV} is still being deleted."
  # So are the copies a world restore kept of the world before each restore.
  for OLD in $(kubectl get pv -l "mc-world-replaced=${SERVER_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
    kubectl patch pv "$OLD" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
  done
  WORLD_LINE="deleted"
fi

echo "Server '${SERVER_NAME}' removed. World: ${WORLD_LINE}."
{
  echo "## Minecraft server \`${SERVER_NAME}\` removed"
  echo ""
  echo "World: ${WORLD_LINE}."
} >> "$SUMMARY"
