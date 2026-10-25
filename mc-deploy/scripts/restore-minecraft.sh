#!/usr/bin/env bash
# Roll a server's world back to one of its nightly Longhorn backups. The server is stopped,
# Longhorn rebuilds the backup as a new volume, and that volume replaces world-data under the
# same name. The current world isn't deleted: its volume is kept (labelled
# mc-world-replaced=<server>) so a restore can be undone. The server starts again if it was
# running before.
#
# Inputs (env): SERVER_NAME, BACKUP (a Longhorn backup name like backup-1a2b3c, or "latest")
set -euo pipefail

SERVER_NAME="${SERVER_NAME:?SERVER_NAME is required}"
BACKUP="${BACKUP:-latest}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
LONGHORN="${LONGHORN_API:-http://longhorn-backend.longhorn-system:9500/v1}"
SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
NAMESPACE="mc-${SERVER_NAME}"

die() { echo "ERROR: $*" >&2; echo "**Failed:** $*" >> "$SUMMARY"; exit 1; }
lh() {   # lh <GET|POST> <path> [json-body]: Longhorn's API (the runners may reach it, see homelab-k8s)
  local args=(-sS --fail-with-body --max-time 60 -X "$1" -H 'Content-Type: application/json')
  [ -n "${3:-}" ] && args+=(-d "$3")
  curl "${args[@]}" "${LONGHORN}$2"
}
[[ "$BACKUP" =~ ^(latest|backup-[a-z0-9]+)$ ]] || die "backup must be 'latest' or a backup name like backup-1a2b3c"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "no server named '${SERVER_NAME}'"
EDITION=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.mc-edition}')

# ---- Which backup ----
OLD_PV=$(kubectl get pvc world-data -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
[ -n "$OLD_PV" ] || die "the server has no world volume"
OLD_VOL=$(kubectl get pv "$OLD_PV" -o jsonpath='{.spec.csi.volumeHandle}')
# Backups follow the world through earlier restores, so look at this volume and every one it
# descends from (a comma-separated list on the PV).
EARLIER=$(kubectl get pv "$OLD_PV" -o jsonpath='{.metadata.annotations.mc-restored-from-volume}')
SOURCES=$(printf '%s,%s' "$OLD_VOL" "$EARLIER" | tr ',' '\n' | grep -v '^$' || true)
ALL='[]'
for v in $SOURCES; do
  BV=$(lh GET /backupvolumes | jq -r --arg v "$v" '.data[] | select(.volumeName == $v) | .id' | head -n1)
  [ -n "$BV" ] || continue
  ALL=$(jq -c --argjson a "$ALL" '$a + [.data[] | select(.state == "Completed")]' <<<"$(lh POST "/backupvolumes/${BV}?action=backupList" '{}')")
done
ALL=$(jq -c 'sort_by(.created) | reverse' <<<"$ALL")
[ "$(jq length <<<"$ALL")" -gt 0 ] || die "'${SERVER_NAME}' has no backups yet (they run nightly at 03:00)"
if [ "$BACKUP" = latest ]; then PICK=$(jq -c '.[0]' <<<"$ALL"); else PICK=$(jq -c --arg b "$BACKUP" 'map(select(.name == $b)) | .[0] // empty' <<<"$ALL"); fi
[ -n "$PICK" ] || die "backup '${BACKUP}' isn't one of '${SERVER_NAME}''s backups"
URL=$(jq -r .url <<<"$PICK"); SIZE=$(jq -r .volumeSize <<<"$PICK"); TAKEN=$(jq -r .created <<<"$PICK"); NAME=$(jq -r .name <<<"$PICK")
echo "== Restoring '${SERVER_NAME}' to ${NAME}, taken ${TAKEN} =="

# ---- Stop the server (it saves the world on the way down) ----
WAS_RUNNING=$(kubectl get deploy minecraft -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
kubectl patch deploy minecraft -n "$NAMESPACE" --type=merge -p '{"spec":{"replicas":0}}'
kubectl wait --for=delete pod -l app=minecraft -n "$NAMESPACE" --timeout=180s || true

# ---- Rebuild the backup as a new Longhorn volume ----
NEW_VOL="mc-${SERVER_NAME}-$(date -u +%Y%m%d-%H%M%S)"
lh POST /volumes "$(jq -nc --arg n "$NEW_VOL" --arg s "$SIZE" --arg u "$URL" \
  '{name: $n, size: $s, fromBackup: $u, numberOfReplicas: 2, dataEngine: "v1", accessMode: "rwo", frontend: "blockdev"}')" >/dev/null
echo "Longhorn is restoring the backup into ${NEW_VOL}..."
for i in $(seq 1 180); do
  V=$(lh GET "/volumes/${NEW_VOL}")
  [ "$(jq -r .restoreRequired <<<"$V")" = false ] && [ "$(jq -r .state <<<"$V")" = detached ] && break
  [ "$i" = 180 ] && die "the restore didn't finish in 30 minutes (volume ${NEW_VOL}); the server is stopped and its world untouched"
  sleep 10
done

# ---- Swap it in under the same name, keeping the old world ----
STAMP=$(date -u +%Y%m%d-%H%M%S)
kubectl label pv "$OLD_PV" mc-world- "mc-world-replaced=${SERVER_NAME}" "mc-replaced-at=${STAMP}" --overwrite >/dev/null
kubectl delete pvc world-data -n "$NAMESPACE" --wait=true
lh POST "/volumes/${NEW_VOL}?action=pvCreate" "$(jq -nc --arg n "$NEW_VOL" '{pvName: $n, fsType: "ext4", storageClassName: "longhorn-retain"}')" >/dev/null
lh POST "/volumes/${NEW_VOL}?action=pvcCreate" "$(jq -nc --arg ns "$NAMESPACE" '{namespace: $ns, pvcName: "world-data"}')" >/dev/null
for i in $(seq 1 30); do
  [ "$(kubectl get pvc world-data -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break
  [ "$i" = 30 ] && die "the restored world (PV ${NEW_VOL}) didn't bind; the old world is PV ${OLD_PV}"
  sleep 2
done
kubectl patch pv "$NEW_VOL" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
kubectl label pv "$NEW_VOL" "mc-world=${SERVER_NAME}" "mc-edition=${EDITION}" --overwrite >/dev/null
kubectl annotate pv "$NEW_VOL" "mc-restored-from-volume=${OLD_VOL}${EARLIER:+,${EARLIER}}" "mc-restored-backup=${NAME}" --overwrite >/dev/null

# ---- Start again if it was running ----
if [ "${WAS_RUNNING:-0}" != 0 ]; then
  kubectl patch deploy minecraft -n "$NAMESPACE" --type=merge -p '{"spec":{"replicas":1}}'
  kubectl rollout status deploy/minecraft -n "$NAMESPACE" --timeout=20m ||
    { kubectl logs -n "$NAMESPACE" deploy/minecraft --tail=40 || true; die "the restored world didn't start (old world kept as PV ${OLD_PV})"; }
  STATE="and is running again"
else
  STATE="(it was stopped, so it stays stopped)"
fi

{
  echo "## '${SERVER_NAME}' restored to the backup from ${TAKEN} ${STATE}"
  echo
  echo "The world before the restore is kept as PV \`${OLD_PV}\` (label \`mc-world-replaced=${SERVER_NAME}\`)."
  echo "To undo: restore again and pick a newer backup, or ask for that PV to be swapped back."
} | tee -a "$SUMMARY"
