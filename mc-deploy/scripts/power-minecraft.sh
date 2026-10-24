#!/usr/bin/env bash
# Start, stop or restart an existing server. Stopping keeps everything (world, port, settings)
# and closes the router port; starting brings it back and reopens the port if it was public.
#
# Inputs (env): SERVER_NAME, ACTION (start|stop|restart)
set -euo pipefail

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
ACTION="${ACTION:?ACTION is required}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
LB_IP="192.168.10.242"
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
NAMESPACE="mc-${SERVER_NAME}"

die() { echo "ERROR: $*" >&2; echo "**Failed:** $*" >> "$SUMMARY"; exit 1; }
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "no server named '${SERVER_NAME}'"
PORT=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.mc-port}')
EDITION=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.mc-edition}')
PUBLIC=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.mc-public}')
PROTO=$([ "$EDITION" = bedrock ] && echo udp || echo tcp)

# Patch replicas directly: the runner may patch Deployments but not use the /scale subresource.
set_replicas() { kubectl patch deploy minecraft -n "$NAMESPACE" --type=merge -p "{\"spec\":{\"replicas\":$1}}"; }

wait_up() {
  kubectl rollout status deploy/minecraft -n "$NAMESPACE" --timeout=20m ||
    { kubectl logs -n "$NAMESPACE" deploy/minecraft --tail=40 || true; die "the server didn't come back up"; }
}

case "$ACTION" in
  stop)
    echo "== Stopping '${SERVER_NAME}' (the server saves the world on the way down) =="
    set_replicas 0
    kubectl wait --for=delete pod -l app=minecraft -n "$NAMESPACE" --timeout=120s || true
    homelab-port close "$NAMESPACE" || echo "::warning::Couldn't close the router port."
    RESULT="stopped. World, port and settings are kept"
    ;;
  start)
    echo "== Starting '${SERVER_NAME}' =="
    set_replicas 1
    wait_up
    if [ "$PUBLIC" = true ]; then
      homelab-port open "$NAMESPACE" "$PROTO" "$PORT" "$LB_IP" "$PORT" || echo "::warning::Couldn't reopen the router port."
    fi
    RESULT="running"
    ;;
  restart)
    echo "== Restarting '${SERVER_NAME}' =="
    [ "$(kubectl get deploy minecraft -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')" -ge 1 ] || die "it's stopped. Use start."
    kubectl rollout restart deploy/minecraft -n "$NAMESPACE"
    wait_up
    RESULT="restarted"
    ;;
  *) die "action must be start, stop or restart" ;;
esac

echo "'${SERVER_NAME}' ${RESULT}."
echo "## \`${SERVER_NAME}\` ${RESULT}" >> "$SUMMARY"
