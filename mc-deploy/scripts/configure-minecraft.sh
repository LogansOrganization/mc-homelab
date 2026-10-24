#!/usr/bin/env bash
# Changes an existing server's settings (and optionally memory), then restarts it if it's
# running so they take effect. Settings are checked against settings-schema.json; an empty
# value resets that setting to the server's default.
#
# Inputs (env): SERVER_NAME, SETTINGS (JSON object), MEMORY (optional, e.g. 6G)
set -euo pipefail

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
SETTINGS="${SETTINGS:-}"
[ -n "$SETTINGS" ] || SETTINGS='{}'
MEMORY="${MEMORY:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
NAMESPACE="mc-${SERVER_NAME}"

die() { echo "ERROR: $*" >&2; echo "**Failed:** $*" >> "$SUMMARY"; exit 1; }
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "no server named '${SERVER_NAME}'"
EDITION=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.mc-edition}')

source "$(dirname "$0")/settings.sh"
LINES=$(validate_settings "$EDITION" "$SETTINGS") || die "settings rejected (see the error above)"

SET_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  k="${line%%=*}"; v="${line#*=}"
  if [ -n "$v" ]; then SET_ARGS+=("$k=$v"); else SET_ARGS+=("$k-"); fi
  echo "  $k -> ${v:-(default)}"
done <<< "$LINES"

# Merge into the settings recorded on the namespace (empty value = drop it).
OLD=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.annotations.mc-settings}')
[ -n "$OLD" ] || OLD='{}'
NEW=$(printf '%s\n' "$LINES" | jq -Rsc --argjson old "$OLD" '
  reduce (split("\n")[] | select(. != "") | capture("^(?<k>[^=]+)=(?<v>.*)$")) as $e
    ($old; if $e.v == "" then del(.[$e.k]) else .[$e.k] = $e.v end)')

if [ -n "$MEMORY" ]; then
  [[ "$MEMORY" =~ ^([0-9]+)[Gg]$ ]] || die "memory must look like 4G"
  GB="${BASH_REMATCH[1]}"
  (( GB >= 1 && GB <= 16 )) || die "memory must be 1G-16G"
  [ "$EDITION" = java ] && SET_ARGS+=("MEMORY=${GB}G")
  kubectl set resources deploy/minecraft -n "$NAMESPACE" --requests="memory=${GB}Gi" --limits="memory=$((GB + 1))Gi"
  kubectl annotate namespace "$NAMESPACE" "mc-memory=${GB}G" --overwrite >/dev/null
  echo "  memory -> ${GB}G"
fi

[ ${#SET_ARGS[@]} -eq 0 ] || kubectl set env deploy/minecraft -n "$NAMESPACE" "${SET_ARGS[@]}"
kubectl annotate namespace "$NAMESPACE" "mc-settings=${NEW}" --overwrite >/dev/null

# Changing the pod's env/resources restarts it on its own; wait if it's running.
if [ "$(kubectl get deploy minecraft -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')" -ge 1 ]; then
  echo "Restarting so the new settings take effect..."
  kubectl rollout status deploy/minecraft -n "$NAMESPACE" --timeout=20m ||
    { kubectl logs -n "$NAMESPACE" deploy/minecraft --tail=40 || true; die "the server didn't come back up with the new settings"; }
  STATE="applied and restarted"
else
  STATE="saved; they apply when you start it"
fi

echo "Settings for '${SERVER_NAME}' ${STATE}."
{ echo "## \`${SERVER_NAME}\` settings ${STATE}"; echo ""; echo '```'; echo "$NEW" | jq .; echo '```'; } >> "$SUMMARY"
