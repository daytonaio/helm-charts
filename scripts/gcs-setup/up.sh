#!/usr/bin/env bash
# scripts/gcs-setup/up.sh — K8s-native Daytona BYOC bring-up on GCP GKE Standard.
#
# Single interactive entrypoint:
#   1. prompts for cluster name, base domain, project, region
#   2. creates GKE Standard cluster (NOT Autopilot — Autopilot blocks privileged DaemonSets)
#      with Workload Identity enabled + ubuntu_containerd node image
#   3. adds sandbox node pool with daytona-sandbox-c label + sandbox=true:NoSchedule taint
#   4. creates GCS bucket + Google Service Account + HMAC keys (S3 interop)
#   5. updates kubeconfig
#   6. labels daytona namespace pod-security.kubernetes.io/enforce=privileged
#   7. installs ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer
#   8. waits for LoadBalancer IP, prints DNS records
#   9. waits for operator to confirm DNS propagation
#  10. renders values-region.yaml.tmpl and helm-installs daytona-region
#  11. prints proxy URL for sandbox-create testing
#
# See docs/gcp.md for the deployment guide.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/sku-data.sh
source "$SCRIPT_DIR/../_lib/sku-data.sh"
# shellcheck source=../_lib/sku-gcp.sh
source "$SCRIPT_DIR/../_lib/sku-gcp.sh"

omc::need_cmd gcloud kubectl helm envsubst yq jq ssh-keygen curl

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
VALUES_OUT="$STATE_DIR/values-region.yaml"
HMAC_FILE="$STATE_DIR/hmac.env"

if [[ -f "$PROMPTS_FILE" ]]; then
  omc::log INFO "Loading saved prompts from $PROMPTS_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
else
  unset CLUSTER_NAME BASE_DOMAIN REGION_NAME CLUSTER_ISSUER_EMAIL DAYTONA_API_URL \
        GCP_PROJECT GCP_REGION GCS_BUCKET RUNNER_IMAGE_TAG GCP_NODE_MACHINE_TYPE
fi

# === 1. Interactive prompts ==================================================
omc::log INFO "=== Daytona BYOC: GCP GKE Standard bring-up ==="
omc::log INFO "NOTE: this assumes your base domain's DNS is hosted on Cloudflare."
omc::log INFO "      Wildcard preview-cert issuance uses DNS-01 via the Cloudflare API,"
omc::log INFO "      so you'll be asked for a Cloudflare API token below"
omc::log INFO "      (Zone:Read + Zone DNS:Edit, scoped to your domain's zone)."
omc::prompt CLUSTER_NAME "Cluster name" "daytona-byoc-$(date +%Y%m%d-%H%M%S)"
omc::prompt BASE_DOMAIN  "Public base DNS domain"
omc::prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token (Zone:Read + Zone DNS:Edit)"
omc::prompt REGION_NAME  "Daytona region name" "${CLUSTER_NAME}"
omc::prompt CLUSTER_ISSUER_EMAIL "Email for Let's Encrypt ClusterIssuer"
omc::prompt DAYTONA_API_URL "Daytona Cloud API URL" "https://app.daytona.io/api"
omc::prompt_secret DAYTONA_API_KEY "Daytona Cloud admin API key"
omc::prompt GCP_PROJECT "GCP project ID"
omc::prompt GCP_REGION "GCP region" "us-central1"
omc::prompt GCS_BUCKET "GCS bucket name" "${CLUSTER_NAME}-snapshots"
omc::prompt RUNNER_IMAGE_TAG "Runner image tag" "v0.183.0"

GCS_LOCATION="$GCP_REGION"
RUNNER_AWS_CREDENTIAL_MODE="static"
GCP_SERVICE_ACCOUNT_EMAIL=""

{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n'  "$BASE_DOMAIN"
  printf 'export REGION_NAME=%q\n'  "$REGION_NAME"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "$CLUSTER_ISSUER_EMAIL"
  printf 'export DAYTONA_API_URL=%q\n' "$DAYTONA_API_URL"
  printf 'export GCP_PROJECT=%q\n'  "$GCP_PROJECT"
  printf 'export GCP_REGION=%q\n'   "$GCP_REGION"
  printf 'export GCS_LOCATION=%q\n' "$GCS_LOCATION"
  printf 'export GCS_BUCKET=%q\n'   "$GCS_BUCKET"
  printf 'export RUNNER_IMAGE_TAG=%q\n' "$RUNNER_IMAGE_TAG"
} > "$PROMPTS_FILE"
chmod 600 "$PROMPTS_FILE"

gcloud config set project "$GCP_PROJECT" >/dev/null

# === 1.5 Quota-aware machine type selection =================================
# 1 system + 1 sandbox per zone * ~3 zones * 4 vCPU = ~24 vCPU per family CPUS quota.
if [[ -z "${GCP_NODE_MACHINE_TYPE:-}" ]]; then
  GCP_NODE_MACHINE_TYPE="$(omc::gcp_select_machine_type "$GCP_REGION" 24 OMC_INSTANCE_TYPE)"
  printf 'export GCP_NODE_MACHINE_TYPE=%q\n' "$GCP_NODE_MACHINE_TYPE" >> "$PROMPTS_FILE"
fi
omc::log INFO "Using GCP machine type: $GCP_NODE_MACHINE_TYPE"

# === 2. GKE Standard cluster =================================================
omc::log INFO "=== Step 2/10: GKE Standard cluster ==="
if gcloud container clusters describe "$CLUSTER_NAME" --region "$GCP_REGION" >/dev/null 2>&1; then
  omc::log INFO "GKE cluster $CLUSTER_NAME already exists in $GCP_REGION"
else
  omc::log INFO "Creating GKE Standard cluster (this takes 5-10 min)..."
  gcloud container clusters create "$CLUSTER_NAME" \
    --region "$GCP_REGION" \
    --workload-pool="${GCP_PROJECT}.svc.id.goog" \
    --image-type=UBUNTU_CONTAINERD \
    --num-nodes=1 \
    --machine-type="${GCP_NODE_MACHINE_TYPE}" \
    --release-channel=stable >/dev/null
fi

# === 3. Sandbox node pool with labels + taints ==============================
omc::log INFO "=== Step 3/10: Sandbox node pool ==="
if gcloud container node-pools describe daytona-sandbox \
    --cluster="$CLUSTER_NAME" --region="$GCP_REGION" >/dev/null 2>&1; then
  omc::log INFO "Sandbox node pool already exists"
else
  gcloud container node-pools create daytona-sandbox \
    --cluster="$CLUSTER_NAME" \
    --region="$GCP_REGION" \
    --image-type=UBUNTU_CONTAINERD \
    --machine-type="${GCP_NODE_MACHINE_TYPE}" \
    --num-nodes=1 \
    --node-labels=daytona-sandbox-c=true \
    --node-taints=sandbox=true:NoSchedule >/dev/null
  omc::log INFO "Sandbox node pool created"
fi

# === 4. GCS bucket + GSA + HMAC ============================================
omc::log INFO "=== Step 4/10: GCS bucket + HMAC keys ==="
if gcloud storage buckets describe "gs://${GCS_BUCKET}" >/dev/null 2>&1; then
  omc::log INFO "GCS bucket gs://${GCS_BUCKET} already exists"
else
  gcloud storage buckets create "gs://${GCS_BUCKET}" --location="$GCS_LOCATION" >/dev/null
  omc::log INFO "Created GCS bucket: gs://${GCS_BUCKET}"
fi

GSA_NAME="daytona-byoc-${CLUSTER_NAME}"
GSA_EMAIL="${GSA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$GSA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$GSA_NAME" \
    --display-name="Daytona BYOC runner ($CLUSTER_NAME)" >/dev/null
  omc::log INFO "Created GSA: $GSA_EMAIL"
fi
gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null 2>&1 || true

if [[ -f "$HMAC_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$HMAC_FILE"
  set +a
  omc::log INFO "Reusing HMAC keys from $HMAC_FILE"
else
  HMAC_OUT="$(gcloud storage hmac create "$GSA_EMAIL" --format=json)"
  HMAC_ACCESS_KEY="$(echo "$HMAC_OUT" | jq -r .metadata.accessId)"
  HMAC_SECRET_KEY="$(echo "$HMAC_OUT" | jq -r .secret)"
  {
    printf 'export HMAC_ACCESS_KEY=%q\n' "$HMAC_ACCESS_KEY"
    printf 'export HMAC_SECRET_KEY=%q\n' "$HMAC_SECRET_KEY"
  } > "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
  omc::log INFO "Created HMAC keys (saved to $HMAC_FILE, 0600)"
fi

# === 5. kubeconfig ===========================================================
omc::log INFO "=== Step 5/10: kubeconfig ==="
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$GCP_REGION" >/dev/null
kubectl config current-context

# === 5b. ENFORCE Ubuntu 24.04 on the sandbox node pool ======================
# The Daytona helm chart docker-installer targets Ubuntu 24.04 (noble) .deb
# packages directly. GKE stable channel + UBUNTU_CONTAINERD image type defaults
# to Ubuntu 24.04 as of K8s 1.31+. Verify and fail-fast if not.
# NO EXCEPTIONS — fail-fast if anything else.
omc::verify_node_ubuntu "24.04" "daytona-sandbox-c=true" 300

# === 6. Namespace + PSA privileged label =====================================
omc::log INFO "=== Step 6/10: daytona namespace + PSA privileged ==="
kubectl create namespace daytona --dry-run=client -o yaml | kubectl apply -f -
# GKE 1.25+ enforces Pod Security Admission by default. The privileged
# runner DaemonSet (sysbox + nsenter into host PID 1) requires the
# enforce=privileged label to be permitted.
kubectl label namespace daytona \
  pod-security.kubernetes.io/enforce=privileged --overwrite

# === 7. ingress-nginx + cert-manager + ClusterIssuer =========================
omc::log INFO "=== Step 7/10: ingress-nginx + cert-manager ==="
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
omc::log INFO "=== Step 8/10: Wait for LoadBalancer + DNS ==="
LB_TARGET="$(omc::wait_lb_address ingress-nginx ingress-nginx-controller 300)"
omc::log INFO "LoadBalancer target: $LB_TARGET"
omc::print_dns_records "$BASE_DOMAIN" "$LB_TARGET"
omc::confirm "Have you created the DNS records above and waited for propagation?" \
  || omc::die "Aborted by operator. Re-run after creating DNS records."

# === 9. SSH keys + render values + helm install ==============================
omc::log INFO "=== Step 9/10: helm install daytona-region ==="
omc::ssh_keys_ensure "$STATE_DIR"
export CLUSTER_NAME BASE_DOMAIN REGION_NAME DAYTONA_API_URL DAYTONA_API_KEY \
       GCS_LOCATION GCS_BUCKET HMAC_ACCESS_KEY HMAC_SECRET_KEY \
       RUNNER_AWS_CREDENTIAL_MODE GCP_SERVICE_ACCOUNT_EMAIL RUNNER_IMAGE_TAG \
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
Snapshot manager:  https://snapshots.${BASE_DOMAIN}

Next steps:
  1. Open Daytona Cloud dashboard for ${REGION_NAME}
  2. Verify runner: kubectl -n daytona get pods
  3. Create a snapshot in this region, then a sandbox from it (web UI or API)
  4. Run smoke test:   bash $SCRIPT_DIR/e2e.sh
  5. Teardown:         bash $SCRIPT_DIR/teardown.sh

Future manual upgrades MUST pass both values files or SSH breaks:
  helm upgrade daytona-region charts/daytona-region -n daytona \\
    -f $VALUES_OUT \\
    -f $STATE_DIR/values-sshgateway-key.yaml

State persisted in: $STATE_DIR
HMAC keys:          $HMAC_FILE (mode 0600 — treat as secret)
===========================================================
EOF
