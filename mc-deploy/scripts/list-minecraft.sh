#!/usr/bin/env bash
# Lists running Minecraft servers and kept worlds, as a table in the job summary.
set -euo pipefail
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
LB_IP="192.168.10.242"
PUBLIC_IP=$(homelab-port public-ip 2>/dev/null || echo "?")

{
  echo "## Minecraft servers"
  echo ""
  echo "| Name | Edition | Type / version | Status | Friends connect to | LAN |"
  echo "|---|---|---|---|---|---|"
  kubectl get namespaces -l app=minecraft -o json | jq -r '.items[] |
    [.metadata.name, .metadata.labels["mc-edition"], (.metadata.annotations["mc-type"] // "?") + " " + (.metadata.annotations["mc-version"] // "?"),
     .metadata.labels["mc-port"], .metadata.labels["mc-public"]] | @tsv' |
  while IFS=$'\t' read -r ns edition typever port public; do
    ready=$(kubectl get deploy minecraft -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    status=$([ "${ready:-0}" -ge 1 ] && echo "up" || echo "starting/down")
    pub=$([ "$public" = true ] && echo "\`${PUBLIC_IP}:${port}\`" || echo "LAN only")
    echo "| ${ns#mc-} | ${edition} | ${typever} | ${status} | ${pub} | \`${LB_IP}:${port}\` |"
  done
  echo ""
  echo "### Kept worlds (not running)"
  echo ""
  kept=$(kubectl get pv -l mc-world -o json | jq -r '.items[] | select(.status.phase == "Released") |
    "- `\(.metadata.labels["mc-world"])` (\(.metadata.labels["mc-edition"] // "java"), \(.spec.capacity.storage))"')
  echo "${kept:-none}"
} >> "$SUMMARY"
