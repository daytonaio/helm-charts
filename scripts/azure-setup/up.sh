#!/usr/bin/env bash
# scripts/azure-setup/up.sh — K8s-native Daytona BYOC bring-up on Azure AKS.
#
# Single interactive entrypoint:
#   1. prompts for cluster name, base domain, region, RG, storage account, blob container
#   2. creates resource group + AKS cluster (Workload Identity ready) + sandbox node pool
#   3. creates Azure Storage Account + Blob container for snapshots
#   4. applies rclone-deployment.yaml.tmpl (S3-compat shim — Azure Blob is not natively S3)
#   5. updates kubeconfig
#   6. installs ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer
#   7. waits for LoadBalancer hostname, prints DNS records
#   8. waits for operator to confirm DNS propagation
#   9. generates SSH gateway keypairs, renders values-region.yaml.tmpl and
#      helm-installs daytona-region
#  10. post-registration: swaps in the region-scoped ssh-gateway api key and
#      advertises the gateway LoadBalancer to Daytona Cloud
#  11. prints proxy URL for sandbox-create testing
#
# Verifies that the AKS docker-installer tarball fallback fires.
# See docs/azure.md for the deployment guide.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/sku-data.sh
source "$SCRIPT_DIR/../_lib/sku-data.sh"
# shellcheck source=../_lib/sku-azure.sh
source "$SCRIPT_DIR/../_lib/sku-azure.sh"

omc::need_cmd az kubectl helm envsubst yq jq openssl ssh-keygen curl

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
VALUES_OUT="$STATE_DIR/values-region.yaml"
RCLONE_OUT="$STATE_DIR/rclone-deployment.yaml"

if [[ -f "$PROMPTS_FILE" ]]; then
  omc::log INFO "Loading saved prompts from $PROMPTS_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
else
  unset CLUSTER_NAME BASE_DOMAIN REGION_NAME CLUSTER_ISSUER_EMAIL DAYTONA_API_URL \
        AZURE_LOCATION RESOURCE_GROUP STORAGE_ACCOUNT BLOB_BUCKET \
        RUNNER_IMAGE_TAG AZURE_NODE_VM_SIZE
fi

# === 1. Interactive prompts ==================================================
omc::log INFO "=== Daytona BYOC: Azure AKS bring-up ==="
omc::prompt CLUSTER_NAME "Cluster name" "daytona-byoc-$(date +%Y%m%d-%H%M%S)"
omc::prompt BASE_DOMAIN  "Public base DNS domain"
omc::prompt REGION_NAME  "Daytona region name" "${CLUSTER_NAME}"
omc::prompt CLUSTER_ISSUER_EMAIL "Email for Let's Encrypt ClusterIssuer"
omc::prompt DAYTONA_API_URL "Daytona Cloud API URL" "https://app.daytona.io/api"
omc::prompt_secret DAYTONA_API_KEY "Daytona Cloud admin API key"
omc::prompt AZURE_LOCATION "Azure region" "eastus"
omc::prompt RESOURCE_GROUP "Azure resource group" "${CLUSTER_NAME}-rg"
DEFAULT_STG="daytonabyoc$(openssl rand -hex 4)"
omc::prompt STORAGE_ACCOUNT "Storage account (lowercase alnum, 3-24 chars, globally unique)" "$DEFAULT_STG"
omc::prompt BLOB_BUCKET "Blob container name" "snapshots"
omc::prompt RUNNER_IMAGE_TAG "Runner image tag" "v0.183.0"

# Azure region alias used by template.
AZURE_REGION="$AZURE_LOCATION"
RUNNER_AWS_CREDENTIAL_MODE="static"
AZURE_CLIENT_ID=""

{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n'  "$BASE_DOMAIN"
  printf 'export REGION_NAME=%q\n'  "$REGION_NAME"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "$CLUSTER_ISSUER_EMAIL"
  printf 'export DAYTONA_API_URL=%q\n' "$DAYTONA_API_URL"
  printf 'export AZURE_LOCATION=%q\n' "$AZURE_LOCATION"
  printf 'export AZURE_REGION=%q\n'  "$AZURE_REGION"
  printf 'export RESOURCE_GROUP=%q\n' "$RESOURCE_GROUP"
  printf 'export STORAGE_ACCOUNT=%q\n' "$STORAGE_ACCOUNT"
  printf 'export BLOB_BUCKET=%q\n'   "$BLOB_BUCKET"
  printf 'export RUNNER_IMAGE_TAG=%q\n' "$RUNNER_IMAGE_TAG"
} > "$PROMPTS_FILE"
chmod 600 "$PROMPTS_FILE"

# === 2. Resource group + AKS =================================================
omc::log INFO "=== Step 2/9: Resource group + AKS ==="

# Preflight: ensure required Azure resource providers are registered on this
# subscription. New subscriptions ship with everything Unregistered.
omc::az_register_providers \
  Microsoft.ContainerService \
  Microsoft.Network \
  Microsoft.Compute \
  Microsoft.Storage

# Quota-aware VM size: 2 system + 1 sandbox nodes share this SKU = 4 vCPU * 3 = 12 vCPU total
if [[ -z "${AZURE_NODE_VM_SIZE:-}" ]]; then
  AZURE_NODE_VM_SIZE="$(omc::azure_select_vm_size "$AZURE_LOCATION" 12 OMC_INSTANCE_TYPE)"
  printf 'export AZURE_NODE_VM_SIZE=%q\n' "$AZURE_NODE_VM_SIZE" >> "$PROMPTS_FILE"
fi
omc::log INFO "Using Azure VM size: $AZURE_NODE_VM_SIZE"

if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az group create --name "$RESOURCE_GROUP" --location "$AZURE_LOCATION" >/dev/null
  omc::log INFO "Created RG: $RESOURCE_GROUP in $AZURE_LOCATION"
else
  existing_rg_loc="$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null)"
  if [[ "$existing_rg_loc" != "$AZURE_LOCATION" ]]; then
    omc::log ERROR ""
    omc::log ERROR "=== RG LOCATION MISMATCH ==="
    omc::log ERROR "  Existing RG '$RESOURCE_GROUP' is in: $existing_rg_loc"
    omc::log ERROR "  You requested:                       $AZURE_LOCATION"
    omc::log ERROR ""
    omc::log ERROR "Creating AKS in a different region than the RG creates an orphaned MC_*"
    omc::log ERROR "node RG that teardown.sh can't clean up. To resolve:"
    omc::log ERROR "  Option A: change AZURE_LOCATION back to '$existing_rg_loc' in prompts.env"
    omc::log ERROR "  Option B: nuke the stale RG first:"
    omc::log ERROR "    az group delete --name $RESOURCE_GROUP --yes --no-wait"
    omc::log ERROR "    rm -rf $STATE_DIR  # then re-run fresh"
    omc::die "Refusing to proceed with mismatched RG/AKS region"
  fi
  omc::log INFO "RG $RESOURCE_GROUP already exists in $existing_rg_loc"
fi

if ! az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  omc::log INFO "Creating AKS cluster (this takes 10-15 min)..."
  az aks create \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$AZURE_LOCATION" \
    --vm-set-type VirtualMachineScaleSets \
    --load-balancer-sku standard \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --os-sku Ubuntu2404 \
    --node-count 2 \
    --node-vm-size "${AZURE_NODE_VM_SIZE}" \
    --generate-ssh-keys >/dev/null
  omc::log INFO "AKS cluster created"
else
  omc::log INFO "AKS cluster $CLUSTER_NAME already exists"
fi

if ! az aks nodepool show --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name sandbox >/dev/null 2>&1; then
  omc::log INFO "Adding sandbox node pool..."
  az aks nodepool add \
    --cluster-name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name sandbox \
    --node-count 1 \
    --node-vm-size "${AZURE_NODE_VM_SIZE}" \
    --os-type Linux \
    --os-sku Ubuntu2404 \
    --labels daytona-sandbox-c=true \
    --node-taints "sandbox=true:NoSchedule" >/dev/null
  omc::log INFO "Sandbox node pool added"
else
  omc::log INFO "Sandbox node pool already exists"
fi

# === 3. Storage Account + Blob container =====================================
omc::log INFO "=== Step 3/9: Storage Account + Blob container ==="
if ! az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$AZURE_LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 >/dev/null
  omc::log INFO "Created storage account: $STORAGE_ACCOUNT"
fi

AZ_STORAGE_KEY="$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' --output tsv)"

az storage container show \
  --name "$BLOB_BUCKET" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$AZ_STORAGE_KEY" >/dev/null 2>&1 || \
  az storage container create \
    --name "$BLOB_BUCKET" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$AZ_STORAGE_KEY" >/dev/null

omc::log INFO "Blob container $BLOB_BUCKET ready"

# === 4. kubeconfig ===========================================================
omc::log INFO "=== Step 4/9: kubeconfig ==="
az aks get-credentials \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --overwrite-existing >/dev/null
kubectl config current-context

# === 4b. ENFORCE Ubuntu 24.04 on all AKS nodes and the sandbox node pool =====
# The Daytona helm chart docker-installer targets Ubuntu 24.04 (noble) .deb
# packages. AKS docker-installer tarball fallback handles the moby-containerd
# conflict, but the deb package URL is still Ubuntu-version-specific.
# NO EXCEPTIONS — fail-fast if anything else.
omc::verify_node_ubuntu "24.04" "" 300
omc::verify_node_ubuntu "24.04" "daytona-sandbox-c=true" 300

# === 5. Namespace ============================================================
omc::log INFO "=== Step 5/9: daytona namespace ==="
kubectl create namespace daytona --dry-run=client -o yaml | kubectl apply -f -

# === 6. rclone-s3-gateway ====================================================
omc::log INFO "=== Step 6/9: rclone S3 gateway (Azure Blob shim) ==="
# Generate gateway credentials (these are the S3-shaped creds the chart will use;
# rclone translates them to Azure Storage Account key under the hood).
RCLONE_S3_KEYS="$STATE_DIR/rclone-keys.env"
if [[ ! -f "$RCLONE_S3_KEYS" ]]; then
  RCLONE_ACCESS_KEY="rclone-$(openssl rand -hex 8)"
  RCLONE_SECRET_KEY="$(openssl rand -hex 24)"
  {
    printf 'export RCLONE_ACCESS_KEY=%q\n' "$RCLONE_ACCESS_KEY"
    printf 'export RCLONE_SECRET_KEY=%q\n' "$RCLONE_SECRET_KEY"
  } > "$RCLONE_S3_KEYS"
  chmod 600 "$RCLONE_S3_KEYS"
  omc::log INFO "Generated rclone gateway credentials -> $RCLONE_S3_KEYS"
else
  set -a
  # shellcheck source=/dev/null
  . "$RCLONE_S3_KEYS"
  set +a
  omc::log INFO "Reusing rclone gateway credentials from $RCLONE_S3_KEYS"
fi

export AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
export AZURE_STORAGE_KEY="$AZ_STORAGE_KEY"
export RCLONE_ACCESS_KEY RCLONE_SECRET_KEY BLOB_BUCKET
omc::render_template "$SCRIPT_DIR/rclone-deployment.yaml.tmpl" "$RCLONE_OUT"
kubectl apply -n daytona -f "$RCLONE_OUT"
kubectl -n daytona rollout status deployment/rclone-s3-gateway --timeout=180s || true

RCLONE_GATEWAY_ENDPOINT="http://rclone-s3-gateway.daytona:8080"

# Persist S3-shaped storage coordinates so migrate-oss-to-byoc.sh path (a) can
# auto-pick them up (it sources $STATE_DIR/byoc-storage.env for BLOB_BUCKET,
# RCLONE_*, RCLONE_GATEWAY_ENDPOINT). Without this the OSS->BYOC migration
# silently skips runner backup storage unless the operator sets RUNNER_S3_*.
{
  printf 'export BLOB_BUCKET=%q\n'             "$BLOB_BUCKET"
  printf 'export RCLONE_ACCESS_KEY=%q\n'       "$RCLONE_ACCESS_KEY"
  printf 'export RCLONE_SECRET_KEY=%q\n'       "$RCLONE_SECRET_KEY"
  printf 'export RCLONE_GATEWAY_ENDPOINT=%q\n' "$RCLONE_GATEWAY_ENDPOINT"
} > "$STATE_DIR/byoc-storage.env"
chmod 600 "$STATE_DIR/byoc-storage.env"
omc::log INFO "Wrote S3-shaped storage coords -> $STATE_DIR/byoc-storage.env (for migrate-oss-to-byoc.sh)"

# === 7. ingress-nginx + cert-manager + ClusterIssuer =========================
omc::log INFO "=== Step 7/9: ingress-nginx + cert-manager ==="
omc::ingress_nginx_install
omc::cert_manager_install
# Wildcard SANs (*.proxy.<domain>) for per-sandbox preview certs can only be
# issued via DNS-01. If a Cloudflare API token is supplied, use the DNS-01
# issuer and enable the wildcard SAN; otherwise install the HTTP-01 issuer and
# keep the proxy cert NON-wildcard so it actually issues (Let's Encrypt cannot
# satisfy a wildcard over HTTP-01). See docs/troubleshooting.md.
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  omc::cluster_issuer_apply_cf_dns01 "$CLUSTER_ISSUER_EMAIL" "$CLOUDFLARE_API_TOKEN"
  PROXY_WILDCARD_TLS=true
else
  omc::cluster_issuer_apply "$CLUSTER_ISSUER_EMAIL"
  PROXY_WILDCARD_TLS=false
fi
export PROXY_WILDCARD_TLS

# === 8. Wait for LoadBalancer + DNS records ==================================
omc::log INFO "=== Step 8/9: Wait for LoadBalancer + DNS ==="
LB_TARGET="$(omc::wait_lb_address ingress-nginx ingress-nginx-controller 300)"
omc::log INFO "LoadBalancer target: $LB_TARGET"
omc::print_dns_records "$BASE_DOMAIN" "$LB_TARGET"
omc::confirm "Have you created the DNS records above and waited for propagation?" \
  || omc::die "Aborted by operator. Re-run after creating DNS records."

# === 9. SSH keys + render values + helm install ==============================
omc::log INFO "=== Step 9/10: helm install daytona-region ==="
omc::ssh_keys_ensure "$STATE_DIR"
export CLUSTER_NAME BASE_DOMAIN REGION_NAME DAYTONA_API_URL DAYTONA_API_KEY \
       AZURE_REGION BLOB_BUCKET RCLONE_GATEWAY_ENDPOINT \
       RCLONE_ACCESS_KEY RCLONE_SECRET_KEY \
       RUNNER_AWS_CREDENTIAL_MODE AZURE_CLIENT_ID RUNNER_IMAGE_TAG \
       INTERNAL_REGISTRY_HOST=""
omc::render_template "$SCRIPT_DIR/values-region.yaml.tmpl" "$VALUES_OUT"
omc::helm_install_wait daytona-region "$SCRIPT_DIR/../../charts/daytona-region" daytona "$VALUES_OUT"

# === 10. Region-scoped ssh-gateway key + sshGatewayUrl =======================
# Cannot happen earlier: the key only exists after the registration hook has
# created the region during helm install.
omc::log INFO "=== Step 10/10: finalize ssh-gateway (region-scoped key) ==="
omc::region_sshgateway_finalize daytona daytona-region \
  "$SCRIPT_DIR/../../charts/daytona-region" "$VALUES_OUT" \
  "$DAYTONA_API_URL" "$DAYTONA_API_KEY"

# === Summary =================================================================
cat >&2 <<EOF

==================== BRING-UP COMPLETE ====================
Proxy URL:         https://proxy.${BASE_DOMAIN}
Snapshot manager:  https://snapshots.${BASE_DOMAIN}  (registry data on PVC)
rclone gateway:    $RCLONE_GATEWAY_ENDPOINT (in-cluster, runner backups only)

Next steps:
  1. Verify AKS docker-installer tarball fallback fired:
       kubectl -n daytona logs daemonset/daytona-region-runner -c docker-installer \\
         | grep -E 'static.*tarball|dockerd not installed by deb'
  2. Open Daytona Cloud dashboard for ${REGION_NAME}
  3. Create a snapshot in this region, then a sandbox from it (web UI or API)
  4. Run smoke test:   bash $SCRIPT_DIR/e2e.sh
  5. Teardown:         bash $SCRIPT_DIR/teardown.sh

Future manual upgrades MUST pass both values files or SSH breaks:
  helm upgrade daytona-region charts/daytona-region -n daytona \\
    -f $VALUES_OUT \\
    -f $STATE_DIR/values-sshgateway-key.yaml

State persisted in: $STATE_DIR
===========================================================
EOF
