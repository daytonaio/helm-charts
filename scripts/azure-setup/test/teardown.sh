#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC — teardown
# =============================================================================
# Cleans up in the right order:
#   1. Delete the runner from Daytona Cloud (so the orphan doesn't sit in the
#      dashboard after the VM is gone)
#   2. Delete the region from Daytona Cloud
#   3. Delete the Azure resource group (VM + AKS + storage + DNS records-ish all
#      vanish at once)
#   4. Delete the Cloudflare DNS A records we wrote (separately - they're outside
#      the RG)
#   5. Delete local state
#
# Usage:
#   ./teardown.sh           # interactive confirmation
#   ./teardown.sh --force   # skip prompt
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RG="${RG:-daytona-byoc-rg}"
DOMAIN="${DOMAIN:-}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
STATE_DIR="$SCRIPT_DIR/.state"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# Recover names from state if available
REGION_NAME="${REGION_NAME:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
REGION_ID=""
if [[ -f "$STATE_DIR/names.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/names.env"
fi
if [[ -f "$STATE_DIR/region-id.txt" ]]; then
  REGION_ID="$(cat "$STATE_DIR/region-id.txt")"
fi

echo
echo "  About to delete:"
echo "    - Azure resource group: $RG"
[[ -n "$REGION_NAME" ]] && echo "    - Daytona Cloud region: $REGION_NAME${REGION_ID:+ (id: $REGION_ID)}"
[[ -n "$RUNNER_NAME" ]] && echo "    - Daytona Cloud runner: $RUNNER_NAME"
[[ -n "$DOMAIN" ]] && echo "    - Cloudflare A records for proxy.$DOMAIN, *.proxy.$DOMAIN, snapshots.$DOMAIN"
echo "    - Local state: $STATE_DIR"
echo

if [[ "$FORCE" != "true" ]]; then
  read -r -p "  Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]] || die "aborted"
fi

# ---- 1. delete runner from Daytona Cloud ----
if [[ -n "$DAYTONA_API_KEY" ]]; then
  log "deleting runner(s) from Daytona Cloud"
  runners="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" 2>/dev/null || echo '[]')"
  for rid in $(echo "$runners" | jq -r --arg n "$RUNNER_NAME" '.[] | select(.name == $n) | .id' 2>/dev/null); do
    log "  deleting runner $rid"
    curl -sS -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
      "$DAYTONA_API_URL/runners/$rid" >/dev/null && ok "deleted runner $rid" \
      || warn "failed to delete runner $rid"
  done
  # Also try by region ID
  if [[ -n "$REGION_ID" ]]; then
    for rid in $(echo "$runners" | jq -r --arg r "$REGION_ID" '.[] | select((.region // {}).id == $r) | .id' 2>/dev/null); do
      curl -sS -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$DAYTONA_API_URL/runners/$rid" >/dev/null && ok "deleted runner $rid (by region)" \
        || true
    done
  fi
else
  warn "no DAYTONA_API_KEY in env - skipping Daytona Cloud runner cleanup"
fi

# ---- 2. delete region from Daytona Cloud ----
if [[ -n "$DAYTONA_API_KEY" && -n "$REGION_ID" ]]; then
  log "deleting region $REGION_ID from Daytona Cloud"
  http="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions/$REGION_ID" || echo 000)"
  if [[ "$http" =~ ^(200|204|404)$ ]]; then
    ok "region delete returned HTTP $http"
  else
    warn "region delete returned HTTP $http - may need manual cleanup in the dashboard"
  fi
fi

# ---- 3. delete Azure resource group ----
log "deleting Azure resource group $RG"
if command -v az >/dev/null 2>&1; then
  if ! az account show >/dev/null 2>&1; then
    az login --use-device-code
  fi
  if az group show --name "$RG" >/dev/null 2>&1; then
    az group delete --name "$RG" --yes --no-wait
    ok "RG delete initiated (runs ~5-10 min in background)"
  else
    ok "RG $RG already gone"
  fi
else
  warn "az not installed - skipping RG delete; do manually: az group delete --name $RG"
fi

# ---- 4. delete Cloudflare A records ----
if [[ -n "$DOMAIN" && -n "$CLOUDFLARE_API_TOKEN" ]]; then
  log "removing Cloudflare A records for $DOMAIN"
  CF_API="https://api.cloudflare.com/client/v4"
  CF_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

  # Find the zone for DOMAIN's parent
  candidate="$DOMAIN"; zone_id=""
  while [[ "$candidate" == *.* ]]; do
    id="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones?name=$candidate" | jq -r '.result[0].id // empty')"
    [[ -n "$id" ]] && { zone_id="$id"; break; }
    candidate="${candidate#*.}"
  done

  if [[ -n "$zone_id" ]]; then
    for fqdn in "proxy.$DOMAIN" "*.proxy.$DOMAIN" "snapshots.$DOMAIN"; do
      existing="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records?name=$fqdn" | jq -r '.result[].id')"
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        curl -sS -X DELETE "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records/$id" >/dev/null \
          && ok "deleted $fqdn"
      done <<< "$existing"
    done
  else
    warn "could not find Cloudflare zone for $DOMAIN - skipping DNS cleanup"
  fi
else
  warn "DOMAIN or CLOUDFLARE_API_TOKEN missing - skipping Cloudflare DNS cleanup"
fi

# ---- 5. local state + kubeconfig context ----
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  ok "removed local state $STATE_DIR"
fi
if command -v kubectl >/dev/null 2>&1; then
  AKS_NAME="${AKS_NAME:-daytona-byoc-aks}"
  kubectl config delete-context "$AKS_NAME" 2>/dev/null || true
  kubectl config delete-cluster "$AKS_NAME" 2>/dev/null || true
  kubectl config delete-user "clusterUser_${RG}_${AKS_NAME}" 2>/dev/null || true
fi

echo
echo "  Teardown complete. Verify with: az group show --name $RG"
echo "  (Expected: ResourceGroupNotFound or 'provisioningState: Deleting')"
