#!/usr/bin/env bash
set -euo pipefail

# ---- Inputs (passed as env vars from the GitHub Actions workflow) ----
# SERVER_NAME   - dns-safe name, e.g. "survival" or "modded-friends"
# MC_VERSION    - e.g. "1.21.1" or "latest"
# MOD_LOADER    - vanilla | paper | forge | fabric | quilt
# MODS          - comma-separated URLs to mod/plugin jars (optional, empty string if none)
# WORLD_SIZE    - PVC size, e.g. "10Gi" (defaults below if unset)
# MEMORY        - e.g. "4G" (defaults below if unset)

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
MC_VERSION="${MC_VERSION:-latest}"
MOD_LOADER="${MOD_LOADER:-vanilla}"
MODS="${MODS:-}"
WORLD_SIZE="${WORLD_SIZE:-10Gi}"
MEMORY="${MEMORY:-4G}"

# sanitize server name: lowercase, alphanumeric + hyphens only, k8s namespace safe
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')
NAMESPACE="mc-${SERVER_NAME}"

# ---- Slot pool config ----
# These must match what's pre-configured in OPNsense (see README for the one-time setup).
# Slot N -> MetalLB IP -> WAN port (all forward to internal port 25565)
SLOT_IPS=("192.168.10.242" "192.168.10.243" "192.168.10.244" "192.168.10.245" "192.168.10.246")
SLOT_PORTS=("25565" "25566" "25567" "25568" "25569")
TOTAL_SLOTS=${#SLOT_IPS[@]}

echo "== Deploying Minecraft server: ${SERVER_NAME} =="

# Refuse to redeploy over an existing server with the same name (avoid double-claiming its slot)
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: A server named '${SERVER_NAME}' already exists (namespace ${NAMESPACE})."
  echo "Destroy it first, or pick a different name."
  exit 1
fi

# Find a free slot by checking which slot numbers are already claimed by existing mc-* namespaces
USED_SLOTS=$(kubectl get namespaces -l app=minecraft -o jsonpath='{.items[*].metadata.labels.mc-slot}' 2>/dev/null || true)

FREE_SLOT=""
for i in $(seq 0 $((TOTAL_SLOTS - 1))); do
  SLOT_NUM=$((i + 1))
  if ! grep -qw "$SLOT_NUM" <<< "$USED_SLOTS"; then
    FREE_SLOT=$SLOT_NUM
    break
  fi
done

if [ -z "$FREE_SLOT" ]; then
  echo "ERROR: All ${TOTAL_SLOTS} server slots are currently in use."
  echo "Destroy an existing server first, or expand the slot pool (see README)."
  exit 1
fi

SLOT_INDEX=$((FREE_SLOT - 1))
LB_IP="${SLOT_IPS[$SLOT_INDEX]}"
WAN_PORT="${SLOT_PORTS[$SLOT_INDEX]}"

echo "Assigned slot ${FREE_SLOT} -> internal IP ${LB_IP} -> public port ${WAN_PORT}"

# ---- Map mod loader to itzg/minecraft-server's TYPE env var + the right mod-loading env var ----
MOD_LOADER_LOWER=$(echo "$MOD_LOADER" | tr '[:upper:]' '[:lower:]')
case "$MOD_LOADER_LOWER" in
  vanilla)
    MOD_LOADER_UPPER="VANILLA"
    MOD_ENV_NAME="MODS"   # unused, harmless if empty
    ;;
  paper)
    MOD_LOADER_UPPER="PAPER"
    MOD_ENV_NAME="PLUGINS"
    ;;
  forge)
    MOD_LOADER_UPPER="FORGE"
    MOD_ENV_NAME="MODS"
    ;;
  fabric)
    MOD_LOADER_UPPER="FABRIC"
    MOD_ENV_NAME="MODS"
    ;;
  quilt)
    MOD_LOADER_UPPER="QUILT"
    MOD_ENV_NAME="MODS"
    ;;
  *)
    echo "ERROR: Unknown mod loader '${MOD_LOADER}'. Use one of: vanilla, paper, forge, fabric, quilt"
    exit 1
    ;;
esac

if [ "$MOD_LOADER_LOWER" = "vanilla" ] && [ -n "$MODS" ]; then
  echo "WARNING: Mods were provided but loader is 'vanilla' - mods will be ignored."
  MODS=""
fi

MEMORY_LIMIT="$MEMORY"

# ---- Render and apply ----
export SERVER_NAME NAMESPACE MC_VERSION MOD_LOADER_UPPER MOD_ENV_NAME MODS WORLD_SIZE MEMORY MEMORY_LIMIT LB_IP SLOT_NUMBER=$FREE_SLOT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envsubst '${SERVER_NAME} ${SLOT_NUMBER} ${WORLD_SIZE} ${MC_VERSION} ${MOD_LOADER_UPPER} ${MOD_ENV_NAME} ${MODS} ${MEMORY} ${MEMORY_LIMIT} ${LB_IP}' \
  < "${SCRIPT_DIR}/../k8s/minecraft-template.yaml" > /tmp/mc-${SERVER_NAME}-rendered.yaml

echo "---- Rendered manifest ----"
cat /tmp/mc-${SERVER_NAME}-rendered.yaml
echo "----------------------------"

kubectl apply -f /tmp/mc-${SERVER_NAME}-rendered.yaml

echo "Waiting for the server pod to become ready (this can take a few minutes on first boot - world gen + mod downloads)..."
kubectl wait --for=condition=ready pod -l app=minecraft -n "$NAMESPACE" --timeout=600s

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "UNKNOWN - check https://whatismyip.com")

echo ""
echo "=================================================="
echo " Server '${SERVER_NAME}' is up!"
echo " Connect at:  ${PUBLIC_IP}:${WAN_PORT}"
echo " (also reachable inside your LAN at ${LB_IP}:25565)"
echo "=================================================="
