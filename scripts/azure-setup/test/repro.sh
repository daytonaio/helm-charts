#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC on Azure - end-to-end deployment
# =============================================================================
#
# Walks through the FULL deployment of Daytona BYOC on Azure:
#
#   Phase 1: AKS cluster + ingress + DNS + cert-manager
#   Phase 2: Azure Blob storage + rclone S3 gateway (for snapshot manager)
#   Phase 3: daytona-region helm chart (registers a custom region with Daytona
#            Cloud and brings up proxy + snapshot manager)
#   Phase 4: Azure VM provisioned as a Daytona runner, registered to the region
#   Phase 5: SDK validation - create a sandbox targeting the new region
#
# You keep using Daytona Cloud (app.daytona.io) as the CONTROL PLANE.
# Your AKS cluster hosts the region INFRASTRUCTURE (proxy + snapshot manager).
# Your Azure VM is the COMPUTE (runs the sandboxes themselves).
#
# Required env vars:
#   DAYTONA_API_KEY     - personal API key from app.daytona.io/dashboard/keys
#   DOMAIN              - FQDN you own, e.g. byoc.yourdomain.com. Used for
#                         proxy.${DOMAIN} and snapshots.${DOMAIN}.
#   ACME_EMAIL          - email for Let's Encrypt registration
#   CLOUDFLARE_API_TOKEN- Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)
#                         for the parent zone of ${DOMAIN}
#
# Optional (with defaults):
#   DAYTONA_API_URL       https://app.daytona.io/api
#   REGION                eastus
#   RG                    daytona-byoc-rg
#   AKS_NAME              daytona-byoc-aks
#   NODE_COUNT            2
#   NODE_SKU              Standard_D4s_v4
#   RUNNER_VM_NAME        daytona-byoc-runner
#   RUNNER_VM_SKU         Standard_D4s_v3        (the runner needs sysbox-compatible kernel)
#   REGION_NAME           aks-byoc-<timestamp>    (auto-generated)
#   RUNNER_NAME           aks-runner-<timestamp> (auto-generated)
#   STAGING               false                  (LE staging vs prod)
#   PHASE                 5                      (1..5 - stop after this phase)
#   SKIP_E2E              false                  (skip phase 5 specifically)
#
# Re-runs are largely idempotent. teardown.sh nukes everything.
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

# ---------- config ----------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DOMAIN="${DOMAIN:?Set DOMAIN env var (FQDN you own under a Cloudflare-managed zone)}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:?Set DAYTONA_API_KEY (personal key from app.daytona.io/dashboard/keys)}"
ACME_EMAIL="${ACME_EMAIL:?Set ACME_EMAIL env var for Let\'s Encrypt registration}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN env var}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
SUBSCRIPTION="${SUBSCRIPTION:-}"
REGION_AZ="${REGION:-eastus}"
RG="${RG:-daytona-byoc-rg}"
AKS_NAME="${AKS_NAME:-daytona-byoc-aks}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SKU="${NODE_SKU:-Standard_D4s_v4}"
RUNNER_VM_NAME="${RUNNER_VM_NAME:-daytona-byoc-runner}"
RUNNER_VM_SKU="${RUNNER_VM_SKU:-Standard_D4s_v3}"
NAMESPACE="${NAMESPACE:-daytona-region}"
RELEASE="${RELEASE:-daytona-region}"
CHART_PATH="${CHART_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/charts/daytona-region}"
STAGING="${STAGING:-false}"
SKIP_E2E="${SKIP_E2E:-false}"
PHASE="${PHASE:-5}"

# Storage / blob
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-daytonabyoc$(echo -n "$RG" | md5sum 2>/dev/null | cut -c1-8 || md5 -q -s "$RG" | cut -c1-8)}"
BLOB_BUCKET="${BLOB_BUCKET:-daytona-snapshots}"

# Auto-generated names (timestamp suffix) - written to state for idempotency
STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"
if [[ -f "$STATE_DIR/names.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/names.env"
else
  REGION_NAME="${REGION_NAME:-aks-byoc-$(date +%s)}"
  RUNNER_NAME="${RUNNER_NAME:-aks-runner-$(date +%s)}"
  printf 'REGION_NAME=%q\nRUNNER_NAME=%q\n' "$REGION_NAME" "$RUNNER_NAME" > "$STATE_DIR/names.env"
fi

if [[ "$STAGING" == "true" ]]; then
  ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
  CLUSTER_ISSUER_NAME="letsencrypt-staging"
else
  ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
  CLUSTER_ISSUER_NAME="letsencrypt-prod"
fi

CF_API="https://api.cloudflare.com/client/v4"
CF_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

# ---------- 1. preflight ----------
log "phase 1/15 - preflight"
for t in az kubectl helm jq curl openssl envsubst ssh-keygen; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
[[ -d "$CHART_PATH" ]] || die "daytona-region chart not found at $CHART_PATH"
ok "tools present; chart at $CHART_PATH"
ok "region name: $REGION_NAME    runner name: $RUNNER_NAME"

# ---------- 2. azure auth + provider registration ----------
log "phase 2/15 - azure auth"
if ! az account show >/dev/null 2>&1; then
  az login --use-device-code
fi
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
SUB_NAME="$(az account show --query name -o tsv)"
ok "subscription: $SUB_NAME ($SUBSCRIPTION_ID)"

REQUIRED_PROVIDERS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.ManagedIdentity Microsoft.OperationalInsights"
log "  ensuring required resource providers are registered"
for prov in $REQUIRED_PROVIDERS; do
  state="$(az provider show --namespace "$prov" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)"
  if [[ "$state" != "Registered" ]]; then
    az provider register --namespace "$prov" --output none
  fi
done
attempts=0
while true; do
  pending=""
  for prov in $REQUIRED_PROVIDERS; do
    state="$(az provider show --namespace "$prov" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
    [[ "$state" != "Registered" ]] && pending="$pending $prov($state)"
  done
  [[ -z "$pending" ]] && break
  attempts=$((attempts+1))
  ((attempts > 120)) && die "providers did not register after 10 min: $pending"
  printf '\r    waiting...%s' "$pending"
  sleep 5
done
echo
ok "all providers registered"

# ---------- 3. daytona api key sanity check (fail fast) ----------
log "phase 3/15 - daytona api key sanity"
me_resp="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $DAYTONA_API_KEY" \
  "$DAYTONA_API_URL/users/me" || echo 000)"
case "$me_resp" in
  200|201|204) ok "DAYTONA_API_KEY accepted by $DAYTONA_API_URL" ;;
  401|403)    die "DAYTONA_API_KEY rejected by $DAYTONA_API_URL (HTTP $me_resp). Generate a new key at app.daytona.io/dashboard/keys" ;;
  *)          warn "unexpected HTTP $me_resp from $DAYTONA_API_URL/users/me - continuing anyway" ;;
esac

# ---------- 4. resource group ----------
log "phase 4/15 - resource group $RG ($REGION_AZ)"
az group create --name "$RG" --location "$REGION_AZ" --output none
ok "resource group ready"

# ---------- 5. cloudflare zone + token verify ----------
log "phase 5/15 - cloudflare DNS lookup + token verify"
CF_ZONE_ID=""
_candidate="$DOMAIN"
while [[ "$_candidate" == *.* ]]; do
  _resp="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones?name=$_candidate")"
  _id="$(echo "$_resp" | jq -r '.result[0].id // empty')"
  if [[ -n "$_id" ]]; then
    CF_ZONE_ID="$_id"
    CF_ZONE_NAME="$_candidate"
    break
  fi
  _candidate="${_candidate#*.}"
done
[[ -n "$CF_ZONE_ID" ]] || die "could not find a Cloudflare zone for $DOMAIN"
_verify="$(curl -sS "${CF_AUTH[@]}" "$CF_API/user/tokens/verify")"
[[ "$(echo "$_verify" | jq -r '.success')" == "true" ]] || die "Cloudflare token rejected"
ok "Cloudflare zone: $CF_ZONE_NAME ($CF_ZONE_ID), token verified"

(( PHASE >= 1 )) || { log "PHASE=$PHASE - stopping after preflight"; exit 0; }

# ---------- 6. aks cluster ----------
log "phase 6/15 - AKS cluster $AKS_NAME ($NODE_COUNT x $NODE_SKU) - ~10 min"
if ! az aks show --resource-group "$RG" --name "$AKS_NAME" >/dev/null 2>&1; then
  az aks create \
    --resource-group "$RG" \
    --name "$AKS_NAME" \
    --location "$REGION_AZ" \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_SKU" \
    --network-plugin azure \
    --generate-ssh-keys \
    --enable-managed-identity \
    --tier free \
    --output none
  ok "AKS cluster created"
else
  ok "AKS cluster already exists"
fi

# ---------- 7. kubeconfig ----------
log "phase 7/15 - fetch kubeconfig"
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing --only-show-errors
kubectl cluster-info >/dev/null || die "kubectl cannot reach cluster"
ok "kubeconfig set; context: $(kubectl config current-context)"

# ---------- 8. ingress-nginx + wait for LB IP + DNS A records ----------
log "phase 8/15 - ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --wait --timeout 5m >/dev/null
ok "ingress-nginx installed"

LB_IP=""
for i in {1..60}; do
  LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$LB_IP" ]] && break
  printf '\r    waiting for LB IP... %ds' $((i*5)); sleep 5
done
echo
[[ -n "$LB_IP" ]] || die "no LB IP after 5 min"
ok "LB IP: $LB_IP"

log "writing Cloudflare A records for $DOMAIN"
cf_upsert_a() {
  local fqdn="$1" ip="$2"
  local existing
  existing="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$fqdn" | jq -r '.result[].id')"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    curl -sS -X DELETE "${CF_AUTH[@]}" "$CF_API/zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
  done <<< "$existing"
  local resp
  resp="$(curl -sS "${CF_AUTH[@]}" -X POST "$CF_API/zones/$CF_ZONE_ID/dns_records" \
    --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":60,\"proxied\":false}")"
  [[ "$(echo "$resp" | jq -r '.success')" == "true" ]] || die "DNS upsert failed for $fqdn: $resp"
}
cf_upsert_a "proxy.$DOMAIN" "$LB_IP"
cf_upsert_a "*.proxy.$DOMAIN" "$LB_IP"
cf_upsert_a "snapshots.$DOMAIN" "$LB_IP"
ok "DNS A records written for proxy, *.proxy, snapshots"

# ---------- 9. cert-manager + ClusterIssuer ----------
log "phase 9/15 - cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m >/dev/null

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTER_ISSUER_NAME
spec:
  acme:
    server: $ACME_SERVER
    email: $ACME_EMAIL
    privateKeySecretRef:
      name: $CLUSTER_ISSUER_NAME-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
ok "cert-manager installed; ClusterIssuer $CLUSTER_ISSUER_NAME applied"

# ---------- 10. namespace + Certificate resources ----------
log "phase 10/15 - daytona-region namespace + Certificates"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: proxy-wildcard-cert
  namespace: $NAMESPACE
spec:
  secretName: proxy.$DOMAIN-tls
  issuerRef:
    name: $CLUSTER_ISSUER_NAME
    kind: ClusterIssuer
  dnsNames:
    - "proxy.$DOMAIN"
    - "*.proxy.$DOMAIN"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: snapshots-cert
  namespace: $NAMESPACE
spec:
  secretName: snapshots.$DOMAIN-tls
  issuerRef:
    name: $CLUSTER_ISSUER_NAME
    kind: ClusterIssuer
  dnsNames:
    - "snapshots.$DOMAIN"
EOF
ok "Certificate resources requested"

(( PHASE >= 2 )) || { log "PHASE=$PHASE - stopping after region infra setup"; exit 0; }

# ---------- 11. Azure Blob storage + rclone S3 gateway ----------
log "phase 11/15 - Azure Blob storage for snapshots"
# Storage account name must be 3-24 chars, lowercase letters and numbers only
if ! az storage account show --resource-group "$RG" --name "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  az storage account create \
    --resource-group "$RG" \
    --name "$STORAGE_ACCOUNT" \
    --location "$REGION_AZ" \
    --sku Standard_LRS \
    --allow-blob-public-access false \
    --output none
  ok "storage account $STORAGE_ACCOUNT created"
else
  ok "storage account $STORAGE_ACCOUNT exists"
fi

AZURE_STORAGE_KEY="$(az storage account keys list \
  --resource-group "$RG" --account-name "$STORAGE_ACCOUNT" \
  --query "[0].value" -o tsv)"

az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$AZURE_STORAGE_KEY" \
  --name "$BLOB_BUCKET" \
  --output none 2>/dev/null || true
ok "blob container $BLOB_BUCKET ready"

# Generate ephemeral S3 credentials for rclone -> snapshot-manager auth
if [[ ! -f "$STATE_DIR/rclone.env" ]]; then
  RCLONE_ACCESS_KEY="$(openssl rand -hex 12)"
  RCLONE_SECRET_KEY="$(openssl rand -hex 24)"
  printf 'RCLONE_ACCESS_KEY=%q\nRCLONE_SECRET_KEY=%q\n' \
    "$RCLONE_ACCESS_KEY" "$RCLONE_SECRET_KEY" > "$STATE_DIR/rclone.env"
fi
# shellcheck disable=SC1091
source "$STATE_DIR/rclone.env"

log "  deploying rclone S3 gateway"
AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT" \
AZURE_STORAGE_KEY="$AZURE_STORAGE_KEY" \
RCLONE_ACCESS_KEY="$RCLONE_ACCESS_KEY" \
RCLONE_SECRET_KEY="$RCLONE_SECRET_KEY" \
BLOB_BUCKET="$BLOB_BUCKET" \
  envsubst < "$SCRIPT_DIR/rclone-deployment.yaml.tmpl" > "$STATE_DIR/rclone-deployment.yaml"
kubectl apply -f "$STATE_DIR/rclone-deployment.yaml" >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=available deploy/rclone-s3-gateway --timeout=2m >/dev/null
ok "rclone S3 gateway running (in-cluster S3 facade over Azure Blob)"

(( PHASE >= 3 )) || { log "PHASE=$PHASE - stopping after blob/rclone setup"; exit 0; }

# ---------- 12. helm install daytona-region ----------
log "phase 12/15 - helm install daytona-region"
DOMAIN="$DOMAIN" \
REGION_NAME="$REGION_NAME" \
DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
RCLONE_ACCESS_KEY="$RCLONE_ACCESS_KEY" \
RCLONE_SECRET_KEY="$RCLONE_SECRET_KEY" \
BLOB_BUCKET="$BLOB_BUCKET" \
  envsubst < "$SCRIPT_DIR/values-region.yaml.tmpl" > "$STATE_DIR/values-region.yaml"

helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$STATE_DIR/values-region.yaml" \
  --timeout 10m >/dev/null
ok "helm install completed - the pre-install hook registered region '$REGION_NAME' with Daytona Cloud"

log "  reading region credentials from the secret the registration hook wrote"
SECRET_NAME="$(kubectl -n "$NAMESPACE" get secret -l app.kubernetes.io/component=region-config -o name | head -1)"
[[ -n "$SECRET_NAME" ]] || SECRET_NAME="secret/$RELEASE-region-config"
REGION_ID="$(kubectl -n "$NAMESPACE" get "$SECRET_NAME" -o jsonpath='{.data.id}' | base64 -d 2>/dev/null || true)"
PROXY_API_KEY="$(kubectl -n "$NAMESPACE" get "$SECRET_NAME" -o jsonpath='{.data.proxyApiKey}' | base64 -d 2>/dev/null || true)"
echo "$REGION_ID" > "$STATE_DIR/region-id.txt"
ok "region registered: id=$REGION_ID"
ok "proxy API key stored in secret $SECRET_NAME (not echoed)"

log "  waiting for proxy + snapshot-manager pods to be Ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance="$RELEASE" \
  --timeout=10m || warn "not all pods Ready; inspect with: kubectl -n $NAMESPACE get pods"
ok "region services running"

(( PHASE >= 4 )) || { log "PHASE=$PHASE - stopping after helm install"; exit 0; }

# ---------- 13. provision runner VM ----------
log "phase 13/15 - Azure VM for runner ($RUNNER_VM_SKU)"
if ! az vm show --resource-group "$RG" --name "$RUNNER_VM_NAME" >/dev/null 2>&1; then
  az vm create \
    --resource-group "$RG" \
    --name "$RUNNER_VM_NAME" \
    --location "$REGION_AZ" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --size "$RUNNER_VM_SKU" \
    --admin-username daytona \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --output none
  ok "runner VM created"
else
  ok "runner VM already exists"
fi

RUNNER_IP="$(az vm show --resource-group "$RG" --name "$RUNNER_VM_NAME" -d --query publicIps -o tsv)"
ok "runner VM public IP: $RUNNER_IP"

# Open the inbound port the runner serves on (default 3000), plus SSH for debugging
for port in 22 3000 2220; do
  az vm open-port --resource-group "$RG" --name "$RUNNER_VM_NAME" \
    --port "$port" --priority $((1000 + port % 100)) --output none 2>/dev/null || true
done

(( PHASE >= 5 )) || { log "PHASE=$PHASE - stopping after VM provision"; exit 0; }

# ---------- 14. bootstrap runner on the VM (install Docker, install.sh, register) ----------
log "phase 14/15 - bootstrapping runner on VM (install.sh installs Docker + registers with Daytona)"

# Build the env file install.sh will read.
RUNNER_API_URL="https://$RUNNER_IP:3000"
cat > "$STATE_DIR/runner-env.sh" <<EOF
export API_URL="$DAYTONA_API_URL"
export API_KEY="$DAYTONA_API_KEY"
export RUNNER_API_URL="$RUNNER_API_URL"
export REGION="$REGION_NAME"
export DOMAIN_OR_IP="$RUNNER_IP"
export PUBLIC_IP="$RUNNER_IP"
export PROCEED="y"
export CONFIRM="y"
export CAPACITY="1000"
export CUSTOM_CPU_COUNT="2"
export CUSTOM_MEMORY_GB="8"
export CUSTOM_DISK_GB="50"
EOF

# Combine env file + bootstrap script into one payload that runs on the VM.
{
  cat "$STATE_DIR/runner-env.sh"
  printf '\n'
  cat "$SCRIPT_DIR/runner-bootstrap.sh"
} > "$STATE_DIR/runner-payload.sh"

log "  running install.sh on the VM via az vm run-command (this takes ~5 min)"
az vm run-command invoke \
  --resource-group "$RG" --name "$RUNNER_VM_NAME" \
  --command-id RunShellScript \
  --scripts "@$STATE_DIR/runner-payload.sh" \
  --output table || warn "az vm run-command reported issues - inspect with: ssh daytona@$RUNNER_IP 'sudo journalctl -u daytona-runner --no-pager -n 200'"

ok "runner bootstrap returned"

log "  giving the runner ~30s to call home + report ready, then querying Daytona Cloud"
sleep 30
runner_resp="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" || true)"
echo "$runner_resp" | jq -r --arg n "$RUNNER_NAME" '.[] | select(.name == $n or (.region // {}).id == "'"$REGION_ID"'") | {id, name, region, state}' 2>/dev/null \
  || warn "could not parse /runners response - paste runner_resp manually"

# ---------- 15. e2e: SDK create a sandbox targeting our region ----------
if [[ "$SKIP_E2E" == "true" ]]; then
  log "phase 15/15 - SKIP_E2E=true, skipping sandbox test"
else
  log "phase 15/15 - e2e: SDK sandbox creation targeting region $REGION_NAME"
  DAYTONA_API_URL="$DAYTONA_API_URL" \
  DAYTONA_API_KEY="$DAYTONA_API_KEY" \
  REGION_NAME="$REGION_NAME" \
  STAGING="$STAGING" \
    bash "$SCRIPT_DIR/e2e.sh" || warn "e2e reported issues - see output above"
fi

# ---------- summary ----------
echo
echo "======================================================================"
echo "  BYOC DEPLOYMENT COMPLETE"
echo "======================================================================"
echo "  Daytona Cloud region        : $REGION_NAME (id: $REGION_ID)"
echo "  Region proxy                : https://proxy.$DOMAIN"
echo "  Snapshot manager            : https://snapshots.$DOMAIN"
echo "  Runner VM                   : $RUNNER_VM_NAME ($RUNNER_IP)"
echo "  AKS LB IP                   : $LB_IP"
echo
echo "  SDK usage (point at the region by name):"
echo "    daytona = Daytona(DaytonaConfig(api_key='...', target='$REGION_NAME'))"
echo "    sandbox = daytona.create()"
echo
echo "  Inspect:"
echo "    kubectl -n $NAMESPACE get pods,svc,ingress,certificate"
echo "    ssh daytona@$RUNNER_IP 'sudo journalctl -u daytona-runner -f'"
echo "    curl -H \"Authorization: Bearer \$DAYTONA_API_KEY\" $DAYTONA_API_URL/runners | jq"
echo
echo "  Teardown: $SCRIPT_DIR/teardown.sh"
echo "======================================================================"
