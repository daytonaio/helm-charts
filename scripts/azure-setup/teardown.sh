#!/usr/bin/env bash
# scripts/azure-setup/teardown.sh — K8s-native Daytona BYOC teardown on Azure AKS.
# Pairs with up.sh. Idempotent. Continues on error.
#
# Strategy: helm uninstall + ns delete first (clean K8s teardown), then
# az group delete (nuclear — removes AKS + storage account + LB + everything in RG).
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  omc::log WARN "$PROMPTS_FILE missing — set CLUSTER_NAME, RESOURCE_GROUP env vars manually"
fi

if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi

: "${CLUSTER_NAME:?CLUSTER_NAME is required (set in $PROMPTS_FILE or env)}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"

omc::log INFO "=== Daytona BYOC: Azure teardown for cluster '$CLUSTER_NAME' in RG '$RESOURCE_GROUP' ==="
omc::confirm "This will DELETE the resource group '$RESOURCE_GROUP' (AKS + storage + everything). Proceed?" \
  || { omc::log INFO "Aborted by operator."; exit 0; }

omc::need_cmd az kubectl helm

# === 1. helm uninstall + delete namespace ====================================
if kubectl get ns daytona >/dev/null 2>&1; then
  helm uninstall daytona-region -n daytona --wait --timeout 5m 2>/dev/null \
    && omc::log INFO "helm uninstalled daytona-region" \
    || omc::log WARN "helm uninstall failed or absent"
  kubectl delete -n daytona deployment/rclone-s3-gateway --wait=false 2>/dev/null || true
  kubectl delete -n daytona service/rclone-s3-gateway --wait=false 2>/dev/null || true
  kubectl delete -n daytona secret/rclone-s3-gateway --wait=false 2>/dev/null || true
  kubectl delete namespace daytona --wait=false 2>/dev/null \
    && omc::log INFO "namespace daytona deletion initiated" \
    || omc::log WARN "namespace delete failed or absent"
fi

# === 2. az group delete (nuclear) ===========================================
if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  omc::log INFO "Deleting resource group $RESOURCE_GROUP (AKS + storage + LB; takes 10-15 min)..."
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait \
    && omc::log INFO "RG delete initiated (async; check 'az group show' to confirm)" \
    || omc::log WARN "RG delete failed (already gone?)"
else
  omc::log INFO "Resource group $RESOURCE_GROUP not found (already gone)"
fi

# === 3. Local state + kubeconfig ============================================
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  omc::log INFO "removed $STATE_DIR"
fi
kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME}" 2>/dev/null || true

cat >&2 <<EOF

==================== TEARDOWN COMPLETE ====================
Verify with:
  az group show --name $RESOURCE_GROUP
    (expect ResourceGroupNotFound or 'provisioningState: Deleting')
===========================================================
EOF
