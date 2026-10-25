#!/usr/bin/env bash
# Deploys one Minecraft server (Java or Bedrock) into its own namespace, mc-<name>.
#
# Every server shares one LAN IP (MetalLB, 192.168.10.242) on its own port:
#   Java    TCP 25565-25579      Bedrock UDP 19132-19146
# With PUBLIC=true the matching port is opened on the OPNsense router (homelab-port, on the
# in-cluster runner) and the public address is printed. Worlds live on longhorn-retain, so a
# teardown keeps them, and deploying the same name again picks the old world back up.
#
# Inputs (env, from the workflow): SERVER_NAME, EDITION (java|bedrock), TYPE, MC_VERSION,
# MODS, MODPACK, MEMORY, CPUS, WORLD_SIZE, PUBLIC, SETTINGS, AUTOSTOP_MINUTES
set -euo pipefail

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
EDITION="${EDITION:-java}"
TYPE="${TYPE:-vanilla}"
MC_VERSION="${MC_VERSION:-latest}"
MODS="${MODS:-}"
MODPACK="${MODPACK:-}"
MEMORY="${MEMORY:-4G}"
WORLD_SIZE="${WORLD_SIZE:-10Gi}"
PUBLIC="${PUBLIC:-true}"
AUTOSTOP_MINUTES="${AUTOSTOP_MINUTES:-30}"
CPUS="${CPUS:-4}"

LB_IP="192.168.10.242"
JAVA_PORTS=$(seq 25565 25579)
BEDROCK_PORTS=$(seq 19132 19146)
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

die() { echo "ERROR: $*" >&2; echo "**Failed:** $*" >> "$SUMMARY"; exit 1; }

SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
[ -n "$SERVER_NAME" ] || die "server name is empty after cleaning it up"
NAMESPACE="mc-${SERVER_NAME}"
case "$EDITION" in java|bedrock) ;; *) die "edition must be java or bedrock" ;; esac
[[ "$AUTOSTOP_MINUTES" =~ ^[0-9]+$ ]] && (( AUTOSTOP_MINUTES <= 1440 )) || die "autostop_minutes must be 0-1440"
[[ "$CPUS" =~ ^[1-4]$ ]] || die "cpus must be 1-4"
[[ "$MEMORY" =~ ^([0-9]+)[Gg]$ ]] || die "memory must look like 4G"
MEM_GB="${BASH_REMATCH[1]}"

echo "== Deploying ${EDITION} server '${SERVER_NAME}' =="
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 &&
  die "a server named '${SERVER_NAME}' already exists. Destroy it first or pick another name."

# ---- Pick the lowest free port for this edition ----
USED=$(kubectl get namespaces -l app=minecraft -o jsonpath='{range .items[*]}{.metadata.labels.mc-port}{"\n"}{end}')
POOL=$([ "$EDITION" = java ] && echo "$JAVA_PORTS" || echo "$BEDROCK_PORTS")
PORT=""
for p in $POOL; do grep -qx "$p" <<< "$USED" || { PORT="$p"; break; }; done
[ -n "$PORT" ] || die "all ${EDITION} ports are in use. Destroy a server first."
if [ "$EDITION" = java ]; then PROTO=tcp; CONTAINER_PORT=25565; else PROTO=udp; CONTAINER_PORT=19132; fi
echo "Port: ${LB_IP}:${PORT}/${PROTO}"

# ---- Reuse a kept world with the same name, if there is one ----
OLD_PV=$(kubectl get pv -l "mc-world=${SERVER_NAME}" -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' | head -n1)
VOLUME_LINE=""
if [ -n "$OLD_PV" ]; then
  OLD_EDITION=$(kubectl get pv "$OLD_PV" -o jsonpath='{.metadata.labels.mc-edition}')
  [ -z "$OLD_EDITION" ] || [ "$OLD_EDITION" = "$EDITION" ] ||
    die "the kept world '${SERVER_NAME}' is a ${OLD_EDITION} world. Use edition ${OLD_EDITION}, or another name."
  WORLD_SIZE=$(kubectl get pv "$OLD_PV" -o jsonpath='{.spec.capacity.storage}')
  kubectl patch pv "$OLD_PV" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
  VOLUME_LINE="  volumeName: ${OLD_PV}"
  echo "Reusing the kept world on ${OLD_PV} (${WORLD_SIZE})"
fi

# ---- Server settings (from the panel/preset; checked against settings-schema.json) ----
source "$(dirname "$0")/settings.sh"
SETTINGS_LINES=$(validate_settings "$EDITION" "${SETTINGS:-}") || die "settings rejected (see the error above)"
declare -A CHOSEN=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  [ -n "${line#*=}" ] && CHOSEN["${line%%=*}"]="${line#*=}"
done <<< "$SETTINGS_LINES"
# Kept on the namespace so the panel can show and edit them later.
SETTINGS_JSON=$(for k in "${!CHOSEN[@]}"; do printf '%s\t%s\n' "$k" "${CHOSEN[$k]}"; done |
  jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}')

# ---- Image + settings per edition/type ----
ENV_YAML=""
add_env() { ENV_YAML+=$'\n'"            - name: $1"$'\n'"              value: $(jq -Rn --arg v "$2" '$v')"; }
default_env() { [ -n "${CHOSEN[$1]:-}" ] || add_env "$1" "$2"; }   # only if the settings didn't set it
add_env EULA "TRUE"
for k in "${!CHOSEN[@]}"; do add_env "$k" "${CHOSEN[$k]}"; done
if [ "$EDITION" = java ]; then
  # Old Minecraft needs old Java; the image tag picks the JVM.
  TAG=latest
  if [ "$MC_VERSION" != latest ] && [[ "$MC_VERSION" =~ ^1\.[0-9]+ ]]; then
    older() { [ "$(printf '%s\n%s\n' "$MC_VERSION" "$1" | sort -V | head -n1)" = "$MC_VERSION" ] && [ "$MC_VERSION" != "$1" ]; }
    if older 1.17; then TAG=java8; elif older 1.20.5; then TAG=java17; elif older 1.22; then TAG=java21; fi
  fi
  IMAGE="itzg/minecraft-server:${TAG}"
  TYPE_UPPER=$(echo "$TYPE" | tr '[:lower:]' '[:upper:]')
  case "$TYPE_UPPER" in
    VANILLA|PAPER|PURPUR|FABRIC|FORGE|NEOFORGE|QUILT) add_env TYPE "$TYPE_UPPER" ;;
    MODRINTH)
      [ -n "$MODPACK" ] || die "type modrinth needs a modpack (a Modrinth slug like 'fabulously-optimized' or its URL)"
      add_env TYPE MODRINTH; add_env MODRINTH_MODPACK "$MODPACK" ;;
    *) die "unknown type '$TYPE'" ;;
  esac
  add_env VERSION "$MC_VERSION"
  add_env MEMORY "${MEM_GB}G"
  add_env USE_AIKAR_FLAGS "true"
  default_env MOTD "${SERVER_NAME} (homelab)"
  # Mods: URLs go to MODS (or PLUGINS for Paper/Purpur), plain names are Modrinth projects.
  if [ -n "$MODS" ]; then
    [ "$TYPE_UPPER" != VANILLA ] || die "vanilla can't load mods. Pick paper/fabric/forge/... instead"
    URLS=(); SLUGS=()
    IFS=',' read -ra ITEMS <<< "$MODS"
    for m in "${ITEMS[@]}"; do m=$(echo "$m" | xargs); [ -z "$m" ] && continue
      if [[ "$m" =~ ^https?:// ]]; then URLS+=("$m"); else SLUGS+=("$m"); fi; done
    if [ ${#URLS[@]} -gt 0 ]; then
      if [[ "$TYPE_UPPER" =~ ^(PAPER|PURPUR)$ ]]; then add_env PLUGINS "$(IFS=,; echo "${URLS[*]}")"
      else add_env MODS "$(IFS=,; echo "${URLS[*]}")"; fi
    fi
    [ ${#SLUGS[@]} -eq 0 ] || add_env MODRINTH_PROJECTS "$(IFS=,; echo "${SLUGS[*]}")"
  fi
  PROBE="tcpSocket:
              port: ${CONTAINER_PORT}"
else
  IMAGE="itzg/minecraft-bedrock-server:latest"
  add_env VERSION "$([ "$MC_VERSION" = latest ] && echo LATEST || echo "$MC_VERSION")"
  default_env SERVER_NAME "${SERVER_NAME} (homelab)"
  [ -z "$MODS$MODPACK" ] || echo "WARNING: Bedrock doesn't take Java mods/modpacks, ignoring them."
  PROBE="exec:
              command: [\"mc-monitor\", \"status-bedrock\", \"--host\", \"127.0.0.1\", \"--port\", \"${CONTAINER_PORT}\"]"
fi
LIMIT_GB=$((MEM_GB + 1))

# Java servers get mc-router in front: while the server is stopped it answers the server list
# with "sleeping", and a join asks the Minecraft panel to start it (the panel runs the Start
# workflow). Bedrock is UDP, which mc-router can't proxy, so players reach it directly.
FRONT=minecraft
ROUTER_YAML=""
if [ "$EDITION" = java ]; then
  FRONT=mc-router
  ROUTER_YAML="
---
apiVersion: v1
kind: Service
metadata:
  name: minecraft-backend
  namespace: ${NAMESPACE}
spec:
  selector:
    app: minecraft
  ports:
    - name: minecraft
      port: 25565
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mc-router
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mc-router
  template:
    metadata:
      labels:
        app: mc-router
    spec:
      containers:
        - name: mc-router
          image: itzg/mc-router:1.47.2@sha256:64ae69eaa7a6800a79bbf962f027f4020878efa25183359115bc7f6ee569c36e
          args:
            - -port=25565
            - -default=minecraft-backend:25565
            - -auto-scale-webhook-url=http://mc-panel.panels.svc/api/wake/${SERVER_NAME}
            # Java clients give up after 30s; the server takes about a minute, so they rejoin.
            - -auto-scale-webhook-wake-timeout=25s
            - -auto-scale-asleep-motd=§e${SERVER_NAME} is sleeping§r - join to wake it (about a minute)
            - -auto-scale-loading-motd=§a${SERVER_NAME} is starting§r - try again in a minute
          ports:
            - containerPort: 25565
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi"
fi

# ---- Apply ----
MANIFEST="/tmp/mc-${SERVER_NAME}.yaml"
cat > "$MANIFEST" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app: minecraft
    # Public-facing, so no privileged containers or host access (Pod Security baseline).
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: baseline
    mc-edition: ${EDITION}
    mc-port: "${PORT}"
    mc-public: "${PUBLIC}"
  annotations:
    mc-type: "${TYPE}"
    mc-version: "${MC_VERSION}"
    mc-memory: "${MEM_GB}G"
    # The Minecraft panel stops the server after this many idle minutes (0 = never).
    mc-autostop: "${AUTOSTOP_MINUTES}"
    mc-cpus: "${CPUS}"
    mc-mods: $(jq -Rn --arg v "$MODS" '$v')
    mc-modpack: $(jq -Rn --arg v "$MODPACK" '$v')
    mc-settings: $(jq -Rn --arg v "$SETTINGS_JSON" '$v')
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: world-data
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-retain
${VOLUME_LINE}
  resources:
    requests:
      storage: ${WORLD_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minecraft
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  # First boot of a big modpack can take a long time; don't call it stuck after the 10 min default.
  progressDeadlineSeconds: 1800
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: minecraft
  template:
    metadata:
      labels:
        app: minecraft
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: minecraft
          image: ${IMAGE}
          env:${ENV_YAML}
          ports:
            - containerPort: ${CONTAINER_PORT}
              protocol: ${PROTO^^}
          volumeMounts:
            - name: world
              mountPath: /data
          # Reserve half a core, burst to CPUS (nodes have 4) when it's busy.
          resources:
            requests:
              cpu: 500m
              memory: "${MEM_GB}Gi"
            limits:
              cpu: "${CPUS}"
              memory: "${LIMIT_GB}Gi"
          # Modpacks can take 10+ minutes to download on first boot.
          startupProbe:
            ${PROBE}
            periodSeconds: 10
            failureThreshold: 120
          readinessProbe:
            ${PROBE}
            periodSeconds: 10
          livenessProbe:
            ${PROBE}
            periodSeconds: 20
            failureThreshold: 6
      volumes:
        - name: world
          persistentVolumeClaim:
            claimName: world-data
---
apiVersion: v1
kind: Service
metadata:
  name: minecraft
  namespace: ${NAMESPACE}
  annotations:
    # All Minecraft servers share one IP; each has its own port.
    metallb.io/allow-shared-ip: minecraft
    metallb.io/loadBalancerIPs: ${LB_IP}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector:
    app: ${FRONT}
  ports:
    - name: minecraft
      port: ${PORT}
      targetPort: ${CONTAINER_PORT}
      protocol: ${PROTO^^}
${ROUTER_YAML}
EOF
kubectl apply -f "$MANIFEST"

# Tag the world's volume so a later deploy with this name can find it.
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/world-data -n "$NAMESPACE" --timeout=120s
PV=$(kubectl get pvc world-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
kubectl label pv "$PV" "mc-world=${SERVER_NAME}" "mc-edition=${EDITION}" --overwrite >/dev/null

echo "Waiting for the server to come up (first boot downloads the server and generates the world)..."
if ! kubectl rollout status deploy/minecraft -n "$NAMESPACE" --timeout=20m; then
  kubectl logs -n "$NAMESPACE" deploy/minecraft --tail=40 || true
  die "the server didn't become ready. Its last log lines are above."
fi

# ---- Open it to the internet ----
PUBLIC_LINE="not opened (public=false)"
if [ "$PUBLIC" = true ]; then
  if homelab-port open "${NAMESPACE}" "$PROTO" "$PORT" "$LB_IP" "$PORT"; then
    PUBLIC_LINE="$(homelab-port public-ip):${PORT}"
    # A name instead of an IP: Java finds the port by itself (SRV), Bedrock needs it typed.
    if [ "$EDITION" = java ] && homelab-dns minecraft "$NAMESPACE" "$SERVER_NAME" "$PORT"; then
      PUBLIC_LINE="${SERVER_NAME}.${HOMELAB_DOMAIN:-solarnebulae.com}"
    elif [ "$EDITION" = bedrock ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
      PUBLIC_LINE="home.${HOMELAB_DOMAIN:-solarnebulae.com} port ${PORT}"
    fi
  else
    PUBLIC_LINE="NOT reachable from the internet: the router port couldn't be opened (see log)"
    echo "::warning::Server is up on the LAN, but the router port couldn't be opened."
  fi
fi

echo ""
echo "=================================================="
echo " '${SERVER_NAME}' is up (${EDITION}, ${TYPE}, ${MC_VERSION})"
echo " Internet: ${PUBLIC_LINE}"
echo " Home LAN: ${LB_IP}:${PORT}"
echo "=================================================="
{
  echo "## Minecraft server \`${SERVER_NAME}\` is up"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| Edition | ${EDITION} (${TYPE}, ${MC_VERSION}) |"
  echo "| **Friends connect to** | \`${PUBLIC_LINE}\` |"
  echo "| On your home network | \`${LB_IP}:${PORT}\` |"
  echo "| World | $([ -n "$OLD_PV" ] && echo "reused the kept world" || echo "new, ${WORLD_SIZE}") |"
  if [ "$EDITION" = bedrock ]; then echo "| Bedrock | Servers tab → Add Server → address + port above |"; fi
} >> "$SUMMARY"
