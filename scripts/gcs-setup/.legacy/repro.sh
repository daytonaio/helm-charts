#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC on GCP — end-to-end setup
# =============================================================================
#
# Walks through the FULL deployment of Daytona BYOC on GCP:
#
#   Phase 1-4: preflight (tools, gcloud auth, Daytona key, Cloudflare token)
#   Phase 5-6: GCS bucket + dedicated service account + HMAC keys
#              (stored in Google Secret Manager — never on disk in cleartext)
#   Phase 7-8: GKE Standard cluster + kubeconfig + VPC discovery
#   Phase 9-11: ingress-nginx + Cloudflare DNS + cert-manager + certificates
#   Phase 12: daytona-region helm chart (registers a custom region with
#             Daytona Cloud and brings up proxy + snapshot manager)
#   Phase 13-14: GCE runner instances (interactive picker) + IAP-SSH bootstrap
#                (registers each as a Daytona runner under our region;
#                fetches HMAC + token from Secret Manager on the box)
#   Phase 15: SDK validation — create a sandbox targeting the new region
#
# You keep using Daytona Cloud (app.daytona.io) as the CONTROL PLANE.
# Your GKE cluster hosts the region INFRASTRUCTURE (proxy + snapshot manager).
# Your GCE instances are the COMPUTE (run the sandboxes themselves).
#
# Required env vars:
#   DAYTONA_API_KEY      - personal API key from app.daytona.io/dashboard/keys
#   DOMAIN               - FQDN you own, e.g. byoc.yourdomain.com. Used for
#                          proxy.${DOMAIN} and snapshots.${DOMAIN}.
#   ACME_EMAIL           - email for Let's Encrypt registration
#   CLOUDFLARE_API_TOKEN - Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)
#                          for the parent zone of ${DOMAIN}
#   GCP_PROJECT          - your GCP project ID
#
# GCP auth - both required (this script verifies via `gcloud auth list`):
#   gcloud auth login                          # for gcloud commands
#   gcloud auth application-default login      # for client libraries (used by
#                                                kubectl-via-gke-gcloud-auth-plugin)
#
# Optional (with defaults):
#   DAYTONA_API_URL          https://app.daytona.io/api
#   GCP_REGION               us-central1
#   GCP_ZONE                 us-central1-a    (where runner VMs live)
#   CLUSTER_NAME             daytona-byoc-gke (suffixed with stable hash of DOMAIN)
#   K8S_VERSION              ""                (let GCP pick the default channel)
#   NODE_MACHINE_TYPE        e2-standard-4    (for GKE control-plane pods)
#   NODE_COUNT               2                 (GKE node count)
#   RUNNER_COUNT             4                 (n2-standard-8 each — matches the
#                                                prod-shape 16 sandboxes × 4 vCPU
#                                                × 2x over-prov sizing)
#   RUNNER_MACHINE_TYPE      n2-standard-8    (set to skip the interactive picker)
#   RUNNER_DISK_GB           100
#   REGION_NAME              gke-byoc-<timestamp>    (auto)
#   RUNNER_NAME_PREFIX       gke-runner             (each instance gets a numeric suffix)
#   STAGING                  false                  (LE staging vs prod CA)
#   PHASE                    5                      (1..5 — stop after this phase)
#   SKIP_E2E                 false
#   NON_INTERACTIVE          false                  (skip instance picker prompts)
#
# Re-runs are largely idempotent. teardown.sh nukes everything.
# =============================================================================

set -euo pipefail

# IMPORTANT: all status/log functions write to STDERR (not stdout) so that
# functions which return values via stdout (e.g. `register_runner` echoes
# the secret name) can use log/ok/warn for progress messages without those
# messages being silently captured by `$(...)` command substitution.
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2 ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" >&2 ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" >&2 ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

# Cross-platform `shred`: prefer GNU coreutils' `shred` then fall back to
# `gshred` (macOS via brew install coreutils). If neither is present, we
# overwrite once with /dev/urandom + remove, which still beats a plain `rm`.
secure_rm() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -z -n 1 "$f" 2>/dev/null && return 0
  fi
  if command -v gshred >/dev/null 2>&1; then
    gshred -u -z -n 1 "$f" 2>/dev/null && return 0
  fi
  # Fallback: write garbage over it, then remove. Not as good as shred but
  # at least the cleartext doesn't sit on disk waiting for unlink GC.
  local sz
  sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
  [[ "$sz" -gt 0 ]] && dd if=/dev/urandom of="$f" bs=1 count="$sz" conv=notrunc 2>/dev/null || true
  rm -f "$f"
}

# wait_for_sa <sa-email> — poll until the service account is queryable by IAM.
# GCP IAM is eventually consistent: a freshly-created SA appears on
# `gcloud iam service-accounts describe` within 1-2s, but can take 10-60s
# to propagate to other services' IAM-check planes (Cloud Storage,
# Secret Manager, Pub/Sub, etc.). This is the first line of defense;
# iam_bind_with_retry below is the actual safety net for binding ops.
wait_for_sa() {
  local sa="$1"
  local max="${2:-30}"     # ~60s total
  local attempt=0
  while (( attempt < max )); do
    if gcloud iam service-accounts describe "$sa" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

# iam_bind_with_retry <gcloud-cmd...> — run an IAM binding command with
# automatic retry on the well-known eventual-consistency errors GCP
# returns when the principal hasn't propagated yet. Surfaces any other
# error immediately so we don't mask real problems (typos, missing roles,
# etc.). ~2 minutes of total backoff before giving up.
iam_bind_with_retry() {
  local max=24
  local attempt=0
  local err_file
  while (( attempt < max )); do
    err_file="$(mktemp)"
    if "$@" >/dev/null 2>"$err_file"; then
      rm -f "$err_file"
      [[ $attempt -gt 0 ]] && echo >&2  # newline after the spinner if we waited
      return 0
    fi
    local stderr
    stderr="$(cat "$err_file")"
    rm -f "$err_file"
    if echo "$stderr" | grep -qE 'does not exist|NOT_FOUND|PERMISSION_DENIED|propagat|400.*Service account'; then
      attempt=$((attempt + 1))
      printf '\r    waiting for IAM propagation... %ds  ' $((attempt * 5)) >&2
      sleep 5
      continue
    fi
    # Non-retryable error — surface it verbatim
    echo "$stderr" >&2
    return 1
  done
  echo >&2
  echo "ERROR: iam_bind_with_retry exhausted after ~2 minutes" >&2
  return 1
}

# ---------- config ----------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DOMAIN="${DOMAIN:?Set DOMAIN env var (FQDN you own under a Cloudflare-managed zone)}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:?Set DAYTONA_API_KEY (personal key from app.daytona.io/dashboard/keys)}"
ACME_EMAIL="${ACME_EMAIL:?Set ACME_EMAIL env var for Let\'s Encrypt registration}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN env var}"
GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT env var (your GCP project ID)}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
GCP_REGION="${GCP_REGION:-us-central1}"
# GCP_ZONE is auto-resolved in phase 4.6 if not set explicitly. We can't
# default to ${GCP_REGION}-a here because not every GCP region has a zone
# named -a (e.g. us-east1 only has -b/-c/-d). Setting this to empty for
# now and resolving once gcloud auth is verified later.
GCP_ZONE="${GCP_ZONE:-}"

# Stable cluster name suffix derived from $DOMAIN so re-runs hit the same
# cluster. Keeps the cluster name <40 chars (GKE limit is 40 incl. region).
_hash="$(printf '%s' "$DOMAIN" | shasum | cut -c1-6)"
CLUSTER_NAME="${CLUSTER_NAME:-daytona-byoc-gke-$_hash}"
K8S_VERSION="${K8S_VERSION:-}"
NODE_MACHINE_TYPE="${NODE_MACHINE_TYPE:-e2-standard-4}"
NODE_COUNT="${NODE_COUNT:-2}"
RUNNER_COUNT="${RUNNER_COUNT:-4}"
RUNNER_MACHINE_TYPE="${RUNNER_MACHINE_TYPE:-}"  # if empty, picker prompts in phase 13
RUNNER_DISK_GB="${RUNNER_DISK_GB:-100}"

NAMESPACE="${NAMESPACE:-daytona-region}"
RELEASE="${RELEASE:-daytona-region}"
CHART_PATH="${CHART_PATH:-$SCRIPT_DIR/../../../charts/daytona-region}"
STAGING="${STAGING:-false}"
SKIP_E2E="${SKIP_E2E:-false}"
PHASE="${PHASE:-5}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# Per-runner resource hints reported to Daytona (CPU/MEM/DISK advertised
# to the scheduler). Empty here so the phase 13 picker / sku.env restore
# can populate them. Final fallback values are set right before phase 13c.
CUSTOM_CPU_COUNT="${CUSTOM_CPU_COUNT:-}"
CUSTOM_MEMORY_GB="${CUSTOM_MEMORY_GB:-}"
CUSTOM_DISK_GB="${CUSTOM_DISK_GB:-}"

# State directory. Sourcing names.env here pulls in REGION_NAME (if set
# from a previous run) as a *hint* — phase 4.7 decides definitively whether
# to use it or pick a different region. All resource names that derive
# from REGION_NAME are computed AFTER phase 4.7.
STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"
if [[ -f "$STATE_DIR/names.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/names.env"
fi
REGION_NAME="${REGION_NAME:-}"
REGION_ID="${REGION_ID:-}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-gke-runner}"
PICKED_EXISTING_REGION="false"

# Re-runs: restore the SKU + resource choices the user made the first time
# around so we don't re-prompt or surprise them with a different default.
if [[ -f "$STATE_DIR/sku.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/sku.env"
fi

# Cluster labels — handy for teardown filtering (the VALUE gets set after
# the picker resolves REGION_NAME below)
REGION_LABEL_KEY="daytona-region"

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
log "phase 1/15 — preflight"
for t in gcloud kubectl helm jq curl openssl envsubst shasum python3; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
[[ -d "$CHART_PATH" ]] || die "daytona-region chart not found at $CHART_PATH"
# gke-gcloud-auth-plugin: kubectl talks to GKE via this plugin since 1.26.
# Install with: gcloud components install gke-gcloud-auth-plugin
command -v gke-gcloud-auth-plugin >/dev/null 2>&1 || \
  warn "gke-gcloud-auth-plugin not found — kubectl will fail to reach the cluster.
        Fix with: gcloud components install gke-gcloud-auth-plugin"
ok "tools present; chart at $CHART_PATH"
ok "project: $GCP_PROJECT    region: $GCP_REGION    zone: $GCP_ZONE"
ok "region name: $REGION_NAME    runner prefix: $RUNNER_NAME_PREFIX (×$RUNNER_COUNT)"
ok "cluster: $CLUSTER_NAME"

# ---------- 2. gcloud auth ----------
log "phase 2/15 — gcloud auth"
# Active account (login)
active_acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
[[ -n "$active_acct" ]] || die "gcloud not authenticated. Run: gcloud auth login"
# Application Default Credentials (used by kubectl + some client libs)
adc_file="${CLOUDSDK_AUTH_ADC_FILE:-$HOME/.config/gcloud/application_default_credentials.json}"
[[ -f "$adc_file" ]] || die "Application Default Credentials missing. Run: gcloud auth application-default login"
# Project exists + access
proj_id="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectId)' 2>/dev/null || true)"
[[ "$proj_id" == "$GCP_PROJECT" ]] || die "cannot describe project '$GCP_PROJECT' (check ID + IAM)"
gcloud config set project "$GCP_PROJECT" --quiet >/dev/null
ok "auth: $active_acct  ADC: present  project: $GCP_PROJECT"

# ---------- 3. daytona api key sanity check (fail fast) ----------
log "phase 3/15 — daytona api key sanity"
_resp_body="$(mktemp)"
_http="$(curl -sS -o "$_resp_body" -w '%{http_code}' \
  -H "Authorization: Bearer $DAYTONA_API_KEY" \
  -H "Accept: application/json" \
  "$DAYTONA_API_URL/regions" 2>/dev/null || echo 000)"
case "$_http" in
  200|201|204)
    ok "DAYTONA_API_KEY accepted by $DAYTONA_API_URL (GET /regions -> $_http)"
    rm -f "$_resp_body"
    ;;
  401|403)
    echo
    warn "HTTP $_http response body:"
    head -c 500 "$_resp_body" | sed 's/^/    /'; echo
    rm -f "$_resp_body"
    die "DAYTONA_API_KEY rejected by $DAYTONA_API_URL (HTTP $_http).
    Check:
      1. The key was copied without leading/trailing whitespace.
      2. The key starts with 'dtn_'.
      3. The key was generated at app.daytona.io/dashboard/keys."
    ;;
  000)
    rm -f "$_resp_body"
    die "could not reach $DAYTONA_API_URL (curl failed — DNS/network issue?)"
    ;;
  *)
    warn "unexpected HTTP $_http from $DAYTONA_API_URL/regions — continuing"
    rm -f "$_resp_body"
    ;;
esac

# ---------- 4. cloudflare zone + token verify ----------
log "phase 4/15 — cloudflare DNS lookup + token verify"
CF_ZONE_ID=""
CF_ZONE_NAME=""
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

# ---------- 4.5 enable required GCP APIs (fast no-op if already on) ----------
log "phase 4.5/15 — enable GCP APIs"
REQUIRED_APIS=(
  container.googleapis.com
  compute.googleapis.com
  storage.googleapis.com
  secretmanager.googleapis.com
  iap.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  serviceusage.googleapis.com
  artifactregistry.googleapis.com
)
# Enable in one batch — gcloud accepts multiple service names
gcloud services enable "${REQUIRED_APIS[@]}" --project="$GCP_PROJECT" --quiet >/dev/null
ok "APIs enabled: ${REQUIRED_APIS[*]}"

# ---------- 4.6 resolve GCP_ZONE within GCP_REGION ----------
# Not every region has a zone named `-a` (e.g. us-east1 only has -b/-c/-d).
# So we either (a) trust an explicitly-set GCP_ZONE and verify it belongs to
# $GCP_REGION, or (b) auto-pick the alphabetically-first UP zone in the
# region. Done after the compute API is enabled in phase 4.5.
log "phase 4.6/15 — resolving GCP_ZONE in $GCP_REGION"
if [[ -n "$GCP_ZONE" ]]; then
  # User explicitly set GCP_ZONE — verify it belongs to GCP_REGION
  zone_region="$(gcloud compute zones describe "$GCP_ZONE" \
    --project="$GCP_PROJECT" --format='value(region)' 2>/dev/null \
    | awk -F/ '{print $NF}' || true)"
  if [[ -z "$zone_region" ]]; then
    die "GCP_ZONE=$GCP_ZONE does not exist (or compute API not yet propagated)"
  fi
  if [[ "$zone_region" != "$GCP_REGION" ]]; then
    die "GCP_ZONE=$GCP_ZONE is in region '$zone_region', not GCP_REGION=$GCP_REGION.
        Either unset GCP_ZONE (to auto-pick) or align it with GCP_REGION."
  fi
  ok "  GCP_ZONE=$GCP_ZONE (user-set, verified in $GCP_REGION)"
else
  # Pick the first UP zone in this region, alphabetically
  GCP_ZONE="$(gcloud compute zones list --project="$GCP_PROJECT" \
    --filter="region:( $GCP_REGION ) AND status=UP" \
    --format='value(name)' 2>/dev/null \
    | sort | head -1)"
  if [[ -z "$GCP_ZONE" ]]; then
    die "no UP zones found in GCP_REGION=$GCP_REGION. Try a different region:
        GCP_REGION=us-east4 ./repro.sh"
  fi
  ok "  GCP_ZONE auto-selected: $GCP_ZONE (first UP zone in $GCP_REGION)"
fi

# ---------- 4.7 Daytona Cloud region selection ----------
# Decides which REGION_NAME to use. Three sources of truth, in priority order:
#
#   1. State file: $STATE_DIR/names.env has REGION_NAME that ALSO exists in
#      Daytona Cloud as a BYOC-managed region. Reuse silently. This is the
#      typical re-run case.
#
#   2. Interactive picker: $STATE_DIR/names.env is missing or stale.
#      Query /api/regions, filter to ones with the 'gke-byoc-' prefix, and
#      offer the user a menu to either reuse one or create a new region.
#
#   3. Fallback (NON_INTERACTIVE=true and no state): auto-create a fresh
#      region with a timestamp-based name.
#
# When user picks an EXISTING region, the script later regenerates that
# region's credentials via /api/regions/{id}/regenerate-* and pre-populates
# the chart's '<release>-region-config' k8s secret. The chart's pre-install
# hook detects the existing secret and skips its own registration call.
log "phase 4.7/15 — Daytona Cloud region selection"

all_regions_json="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/regions" 2>/dev/null || echo '[]')"
byoc_regions_json="$(echo "$all_regions_json" | jq -c '[.[]? | select((.name // "") | startswith("gke-byoc-"))]')"
byoc_count="$(echo "$byoc_regions_json" | jq 'length')"

# Source 1: state has REGION_NAME, verify it still exists in Daytona Cloud
if [[ -n "$REGION_NAME" ]]; then
  match_id="$(echo "$byoc_regions_json" | jq -r --arg n "$REGION_NAME" '.[]? | select(.name == $n) | .id // empty' | head -1)"
  if [[ -n "$match_id" ]]; then
    REGION_ID="$match_id"
    PICKED_EXISTING_REGION="true"
    ok "  reusing region $REGION_NAME (id=$REGION_ID) — from state, verified in Daytona Cloud"
  else
    warn "  state has REGION_NAME=$REGION_NAME but it doesn't exist in Daytona Cloud (deleted?)"
    REGION_NAME=""
    REGION_ID=""
  fi
fi

# Source 2: interactive picker
if [[ -z "$REGION_NAME" && "$NON_INTERACTIVE" != "true" ]]; then
  echo
  echo "  Daytona Cloud regions matching 'gke-byoc-*' prefix:"
  if (( byoc_count == 0 )); then
    echo "    (none — only option is to create a new region)"
  else
    for i in $(seq 0 $((byoc_count - 1))); do
      r_name="$(echo "$byoc_regions_json"  | jq -r ".[$i].name")"
      r_id="$(echo   "$byoc_regions_json"  | jq -r ".[$i].id")"
      r_proxy="$(echo "$byoc_regions_json" | jq -r ".[$i].proxyUrl // \"\"")"
      printf '    %d  %-32s  id=%s\n' "$((i+1))" "$r_name" "$r_id"
      [[ -n "$r_proxy" ]] && printf '       proxy: %s\n' "$r_proxy"
    done
  fi
  printf '    %d  [Create a new region]\n' "$((byoc_count + 1))"
  if (( byoc_count > 0 )); then
    printf '    %d  [DELETE all the above + create new] — destructive, no confirm\n' "$((byoc_count + 2))"
  fi
  echo
  default_choice=$((byoc_count + 1))
  read -r -p "  Choice (1-$((byoc_count + 1 + ( byoc_count > 0 ? 1 : 0 ) )), default=$default_choice = create new): " ans
  ans="${ans:-$default_choice}"

  if (( ans >= 1 && ans <= byoc_count )); then
    # Pick existing
    REGION_NAME="$(echo "$byoc_regions_json" | jq -r ".[$((ans-1))].name")"
    REGION_ID="$(echo   "$byoc_regions_json" | jq -r ".[$((ans-1))].id")"
    PICKED_EXISTING_REGION="true"
    ok "  picked existing region: $REGION_NAME ($REGION_ID)"
  elif (( ans == byoc_count + 1 )); then
    # Create new
    REGION_NAME="gke-byoc-$(date +%s)"
    REGION_ID=""
    PICKED_EXISTING_REGION="false"
    ok "  will create a new region: $REGION_NAME"
  elif (( byoc_count > 0 && ans == byoc_count + 2 )); then
    # Nuke all existing + create new
    log "  deleting $byoc_count existing BYOC-managed region(s) from Daytona Cloud..."
    for i in $(seq 0 $((byoc_count - 1))); do
      del_id="$(echo "$byoc_regions_json" | jq -r ".[$i].id")"
      del_name="$(echo "$byoc_regions_json" | jq -r ".[$i].name")"
      http="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$DAYTONA_API_URL/regions/$del_id" 2>/dev/null || echo 000)"
      case "$http" in
        200|204|404) ok "    deleted $del_name ($del_id) — HTTP $http" ;;
        *)           warn "    delete returned HTTP $http for $del_name ($del_id) — region may have attached runners; cleanup at app.daytona.io/dashboard/regions" ;;
      esac
    done
    REGION_NAME="gke-byoc-$(date +%s)"
    REGION_ID=""
    PICKED_EXISTING_REGION="false"
    ok "  will create a new region: $REGION_NAME"
  else
    die "  invalid choice: $ans"
  fi
fi

# Source 3: non-interactive fallback
if [[ -z "$REGION_NAME" ]]; then
  REGION_NAME="gke-byoc-$(date +%s)"
  REGION_ID=""
  PICKED_EXISTING_REGION="false"
  ok "  non-interactive, no state → creating new region: $REGION_NAME"
fi

# Persist
{
  printf 'REGION_NAME=%q\n' "$REGION_NAME"
  printf 'RUNNER_NAME_PREFIX=%q\n' "$RUNNER_NAME_PREFIX"
  printf 'REGION_ID=%q\n' "${REGION_ID:-}"
  printf 'PICKED_EXISTING_REGION=%q\n' "$PICKED_EXISTING_REGION"
} > "$STATE_DIR/names.env"
[[ -n "$REGION_ID" ]] && echo "$REGION_ID" > "$STATE_DIR/region-id.txt"

# ---- Now derive all resource names from the resolved REGION_NAME ----
# All resource names are deterministic so re-runs land on the same GCP
# resources for a given REGION_NAME.

REGION_LABEL_VALUE="$REGION_NAME"

# GCS bucket name: globally unique, 3-63 chars, lowercase letters / digits /
# hyphens / underscores / dots. We use ${REGION_NAME}-snapshots which is
# always valid.
GCS_BUCKET="${GCS_BUCKET:-${REGION_NAME}-snapshots}"
GCS_BUCKET="$(printf '%s' "$GCS_BUCKET" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"

# Service account IDs: 6-30 chars, lowercase + digits + hyphens, must
# start with a letter. We use a short hash since REGION_NAME can be long.
_sa_hash="$(printf '%s' "$REGION_NAME" | shasum | cut -c1-8)"
GCS_SA_ID="${GCS_SA_ID:-dt-snap-${_sa_hash}}"
GCS_SA_EMAIL="${GCS_SA_ID}@${GCP_PROJECT}.iam.gserviceaccount.com"
RUNNER_SA_ID="${RUNNER_SA_ID:-dt-runner-${_sa_hash}}"
RUNNER_SA_EMAIL="${RUNNER_SA_ID}@${GCP_PROJECT}.iam.gserviceaccount.com"

# Secret Manager resource names. Names only; the actual secret values are
# written in this script then never read from disk.
SECRET_HMAC_ACCESS="${SECRET_HMAC_ACCESS:-daytona-${REGION_NAME}-hmac-access}"
SECRET_HMAC_SECRET="${SECRET_HMAC_SECRET:-daytona-${REGION_NAME}-hmac-secret}"

# Firewall rule names
FW_RUNNER_INGRESS="${FW_RUNNER_INGRESS:-${REGION_NAME}-runner-ingress}"
FW_IAP_SSH="${FW_IAP_SSH:-${REGION_NAME}-iap-ssh}"

ok "  region:          $REGION_NAME (id: ${REGION_ID:-<will-be-created>})"
ok "  GCS bucket:      gs://$GCS_BUCKET"
ok "  snapshot SA:     $GCS_SA_EMAIL"
ok "  runner SA:       $RUNNER_SA_EMAIL"
ok "  HMAC secrets:    $SECRET_HMAC_ACCESS / $SECRET_HMAC_SECRET"

(( PHASE >= 1 )) || { log "PHASE=$PHASE — stopping after preflight"; exit 0; }

# ---------- 5. GCS bucket ----------
log "phase 5/15 — GCS bucket gs://$GCS_BUCKET ($GCP_REGION)"
if gcloud storage buckets describe "gs://$GCS_BUCKET" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "bucket gs://$GCS_BUCKET already exists"
  # If a previous version of this script created the bucket with UBLA,
  # disable it. Why: Daytona's snapshot-manager (built on docker/distribution)
  # sends `x-amz-acl: private` headers when initiating multipart uploads,
  # and UBLA-enabled buckets reject any request bearing ACL headers with
  # HTTP 400 InvalidArgument. The symptom is `docker push` failing with
  # 500 s3aws InvalidArgument on the first POST .../blobs/uploads/. PAP
  # stays on — it only blocks PUBLIC ACLs, not the private one we need.
  ubla_state="$(gcloud storage buckets describe "gs://$GCS_BUCKET" \
    --project="$GCP_PROJECT" \
    --format='value(iamConfiguration.uniformBucketLevelAccess.enabled)' 2>/dev/null || echo unknown)"
  if [[ "$ubla_state" == "True" ]]; then
    warn "  bucket has UBLA enabled — disabling (incompat with docker/distribution S3 driver)"
    gcloud storage buckets update "gs://$GCS_BUCKET" \
      --project="$GCP_PROJECT" \
      --no-uniform-bucket-level-access --quiet >/dev/null
    ok "  UBLA disabled"
  fi
else
  # NB: we INTENTIONALLY do NOT enable UBLA here. UBLA blocks any request
  # that carries an `x-amz-acl` header, and Daytona's snapshot-manager
  # (docker/distribution v2 with the S3 storage driver) always sends
  # `x-amz-acl: private` on CreateMultipartUpload. That trips a 400
  # InvalidArgument from GCS and breaks every snapshot push that uses
  # multipart upload (i.e., any image with a layer > ~5 MB).
  #
  # PAP stays on — it only blocks PUBLIC ACLs (allUsers, etc.) and the
  # snapshot-manager only ever sends `private`, which PAP permits.
  gcloud storage buckets create "gs://$GCS_BUCKET" \
    --project="$GCP_PROJECT" \
    --location="$GCP_REGION" \
    --default-storage-class=STANDARD \
    --public-access-prevention \
    --quiet >/dev/null
  ok "bucket created (PAP enforced; UBLA OFF for docker/distribution compat)"
fi

# ---------- 6. Service account + HMAC keys + Secret Manager ----------
log "phase 6/15 — service account $GCS_SA_EMAIL + HMAC + Secret Manager"

# 6a. Create the service account if missing
sa_freshly_created=false
if ! gcloud iam service-accounts describe "$GCS_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$GCS_SA_ID" \
    --project="$GCP_PROJECT" \
    --display-name="Daytona BYOC snapshot SA ($REGION_NAME)" \
    --description="Owns the HMAC keys for $GCS_BUCKET; used by snapshot-manager and runners" \
    --quiet >/dev/null
  ok "service account $GCS_SA_ID created"
  sa_freshly_created=true
else
  ok "service account already exists"
fi

# Wait for the SA to be visible to other GCP services. Required before
# any add-iam-policy-binding call against a non-IAM resource (Storage,
# Secret Manager, etc.) — without this, you get the textbook 400 "Service
# account ... does not exist" error 1-5 seconds after a successful create.
if [[ "$sa_freshly_created" == "true" ]]; then
  log "  waiting for $GCS_SA_EMAIL to propagate"
  wait_for_sa "$GCS_SA_EMAIL" || warn "  describe still failing — bindings will be retried"
fi

# 6b. Grant the SA objectAdmin on the bucket (least-priv: ONLY on this bucket)
log "  granting roles/storage.objectAdmin on gs://$GCS_BUCKET to $GCS_SA_EMAIL"
iam_bind_with_retry gcloud storage buckets add-iam-policy-binding "gs://$GCS_BUCKET" \
  --project="$GCP_PROJECT" \
  --member="serviceAccount:$GCS_SA_EMAIL" \
  --role="roles/storage.objectAdmin" \
  --condition=None \
  --quiet \
  || die "failed to grant objectAdmin on gs://$GCS_BUCKET to $GCS_SA_EMAIL"
ok "bucket-scoped objectAdmin granted"

# 6c. Mint HMAC keys (idempotent: if a key already exists for this SA we
# use the stored one if available, otherwise rotate). We never write the
# HMAC values to disk — they go straight into Secret Manager.
log "  ensuring HMAC keys exist for the SA"
ensure_secret_with_value() {
  # ensure_secret_with_value <secret-name> <value>
  local name="$1"; local val="$2"
  if gcloud secrets describe "$name" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    # secret exists; add new version (idempotent re-runs are okay)
    printf '%s' "$val" | gcloud secrets versions add "$name" \
      --project="$GCP_PROJECT" --data-file=- --quiet >/dev/null
  else
    gcloud secrets create "$name" \
      --project="$GCP_PROJECT" \
      --replication-policy=automatic \
      --labels="$REGION_LABEL_KEY=$REGION_LABEL_VALUE,managed-by=gcs-repro" \
      --quiet >/dev/null
    printf '%s' "$val" | gcloud secrets versions add "$name" \
      --project="$GCP_PROJECT" --data-file=- --quiet >/dev/null
  fi
}

# Check if both HMAC secrets already exist in Secret Manager. If yes, we
# trust them (i.e. don't rotate every re-run); the corresponding HMAC key
# in IAM must still be ACTIVE for the chart to work. If either is missing,
# mint a fresh HMAC pair and overwrite both secrets.
hmac_secrets_present=true
gcloud secrets describe "$SECRET_HMAC_ACCESS" --project="$GCP_PROJECT" >/dev/null 2>&1 || hmac_secrets_present=false
gcloud secrets describe "$SECRET_HMAC_SECRET" --project="$GCP_PROJECT" >/dev/null 2>&1 || hmac_secrets_present=false

if [[ "$hmac_secrets_present" == "true" ]]; then
  ok "HMAC secrets already present in Secret Manager (reusing)"
else
  log "  minting new HMAC key for $GCS_SA_EMAIL"
  # Deactivate + delete any existing HMAC keys for this SA so we never
  # accumulate dangling credentials.
  for k in $(gcloud storage hmac list --project="$GCP_PROJECT" \
              --service-account="$GCS_SA_EMAIL" \
              --format='value(accessId)' 2>/dev/null); do
    gcloud storage hmac update "$k" --deactivate --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    gcloud storage hmac delete "$k" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
  done
  hmac_json="$(gcloud storage hmac create "$GCS_SA_EMAIL" --project="$GCP_PROJECT" --format=json)"
  hmac_access="$(echo "$hmac_json" | jq -r '.metadata.accessId')"
  hmac_secret="$(echo "$hmac_json" | jq -r '.secret')"
  [[ -n "$hmac_access" && -n "$hmac_secret" ]] || die "failed to mint HMAC keys"

  ensure_secret_with_value "$SECRET_HMAC_ACCESS" "$hmac_access"
  ensure_secret_with_value "$SECRET_HMAC_SECRET" "$hmac_secret"
  unset hmac_json hmac_access hmac_secret
  ok "HMAC keys minted + stored in Secret Manager (values not echoed)"
fi

# Quick sanity check: the snapshot-manager will use these. Read them from
# Secret Manager (single use, no disk write), exercise an S3-ish call via curl.
log "  verifying HMAC keys can reach gs://$GCS_BUCKET via interop XML API"
_acc="$(gcloud secrets versions access latest --secret="$SECRET_HMAC_ACCESS" --project="$GCP_PROJECT")"
_sec="$(gcloud secrets versions access latest --secret="$SECRET_HMAC_SECRET" --project="$GCP_PROJECT")"
attempt=0
until python3 - <<PYEOF >/dev/null 2>&1
import os, sys, hmac, hashlib, base64, datetime, urllib.request
acc = "$_acc"; sec = "$_sec"
bucket = "$GCS_BUCKET"
date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
canon = f"GET\n\n\n{date}\n/{bucket}/"
sig = base64.b64encode(hmac.new(sec.encode(), canon.encode(), hashlib.sha1).digest()).decode()
req = urllib.request.Request(
  f"https://storage.googleapis.com/{bucket}/",
  headers={"Date": date, "Authorization": f"AWS {acc}:{sig}"},
)
urllib.request.urlopen(req, timeout=10).read()
PYEOF
do
  attempt=$((attempt + 1))
  if (( attempt > 20 )); then unset _acc _sec; die "HMAC keys can't reach gs://$GCS_BUCKET after 20 attempts (~60s)"; fi
  printf '\r    waiting for HMAC propagation... %ds' $((attempt * 3)); sleep 3
done
echo
unset _acc _sec
ok "HMAC keys verified against gs://$GCS_BUCKET"

# 6d. Runner SA: separate identity that owns the runner VMs and pulls its
# token + the HMAC values from Secret Manager. Grant it secretAccessor on
# our specific secrets ONLY (per-secret IAM, not project-wide).
runner_sa_freshly_created=false
if ! gcloud iam service-accounts describe "$RUNNER_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$RUNNER_SA_ID" \
    --project="$GCP_PROJECT" \
    --display-name="Daytona BYOC runner SA ($REGION_NAME)" \
    --description="Mounted on runner GCE instances; secretAccessor on this region's secrets only" \
    --quiet >/dev/null
  ok "runner service account $RUNNER_SA_ID created"
  runner_sa_freshly_created=true
else
  ok "runner service account already exists"
fi
if [[ "$runner_sa_freshly_created" == "true" ]]; then
  log "  waiting for $RUNNER_SA_EMAIL to propagate"
  wait_for_sa "$RUNNER_SA_EMAIL" || warn "  describe still failing — bindings will be retried"
fi

# Bind HMAC secrets so the runner SA can read them
for s in "$SECRET_HMAC_ACCESS" "$SECRET_HMAC_SECRET"; do
  iam_bind_with_retry gcloud secrets add-iam-policy-binding "$s" \
    --project="$GCP_PROJECT" \
    --member="serviceAccount:$RUNNER_SA_EMAIL" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --quiet \
    || die "failed to grant secretAccessor on $s to $RUNNER_SA_EMAIL"
done
ok "runner SA granted secretAccessor on HMAC secrets"

# ---------- 7. GKE Standard cluster ----------
log "phase 7/15 — GKE Standard cluster $CLUSTER_NAME (~8-10 min on first run)"
if gcloud container clusters describe "$CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  ok "GKE cluster $CLUSTER_NAME already exists in $GCP_REGION"
elif gcloud container clusters describe "$CLUSTER_NAME" --zone "$GCP_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  ok "GKE cluster $CLUSTER_NAME already exists in $GCP_ZONE (zonal)"
  GKE_LOCATION_FLAG=(--zone "$GCP_ZONE")
else
  # Default: ZONAL cluster (single zone, NODE_COUNT total nodes).
  # We default to zonal because a regional cluster would multiply NODE_COUNT
  # across all 3 zones in the region — `--num-nodes 2` on a regional cluster
  # creates 2 × 3 = 6 nodes, which is more than this repro needs.
  # Set CLUSTER_ZONAL=false to get a regional (HA) cluster instead.
  CLUSTER_ZONAL="${CLUSTER_ZONAL:-true}"
  # Build the gcloud args as a single non-empty array. We intentionally
  # avoid `args=(); [[ cond ]] && args+=(...)` patterns because expanding
  # an empty array via "${args[@]}" under `set -u` fails on bash < 4.4
  # (notably macOS default bash 3.2).
  cluster_args=(--project "$GCP_PROJECT")
  if [[ "$CLUSTER_ZONAL" == "true" ]]; then
    cluster_args+=(--zone "$GCP_ZONE")
  else
    cluster_args+=(--region "$GCP_REGION")
  fi
  [[ -n "$K8S_VERSION" ]] && cluster_args+=(--cluster-version "$K8S_VERSION")
  cluster_args+=(
    --num-nodes "$NODE_COUNT"
    --machine-type "$NODE_MACHINE_TYPE"
    --disk-type pd-standard
    --disk-size 50
    --release-channel regular
    --enable-ip-alias
    --network default
    --subnetwork default
    --workload-pool "${GCP_PROJECT}.svc.id.goog"
    --labels "$REGION_LABEL_KEY=$REGION_LABEL_VALUE,managed-by=gcs-repro"
    --quiet
  )
  gcloud container clusters create "$CLUSTER_NAME" "${cluster_args[@]}" >/dev/null
  ok "GKE cluster created"
fi

# Determine the location flag for subsequent commands (regional vs zonal)
GKE_LOCATION_FLAG=()
if gcloud container clusters describe "$CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  GKE_LOCATION_FLAG=(--region "$GCP_REGION")
else
  GKE_LOCATION_FLAG=(--zone "$GCP_ZONE")
fi

# ---------- 8. kubeconfig + VPC discovery ----------
log "phase 8/15 — kubeconfig + VPC discovery"
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --project "$GCP_PROJECT" "${GKE_LOCATION_FLAG[@]}" --quiet >/dev/null 2>&1
kubectl cluster-info >/dev/null || die "kubectl cannot reach cluster"
ok "kubeconfig set; context: $(kubectl config current-context)"

GKE_NETWORK="$(gcloud container clusters describe "$CLUSTER_NAME" "${GKE_LOCATION_FLAG[@]}" \
  --project "$GCP_PROJECT" --format='value(network)')"
GKE_SUBNET="$(gcloud container clusters describe "$CLUSTER_NAME" "${GKE_LOCATION_FLAG[@]}" \
  --project "$GCP_PROJECT" --format='value(subnetwork)')"
ok "VPC: $GKE_NETWORK  subnetwork: $GKE_SUBNET"

# ---------- 9. ingress-nginx + wait for LB IP + DNS A records ----------
log "phase 9/15 — ingress-nginx + Cloudflare A records"
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
echo "LB_IP=$LB_IP" > "$STATE_DIR/lb.env"

log "  writing Cloudflare A records for $DOMAIN -> $LB_IP"
cf_upsert_a() {
  local fqdn="$1" ip="$2"
  local existing
  existing="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$fqdn" | jq -r '.result[].id')"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
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

# ---------- 10. cert-manager + ClusterIssuer ----------
log "phase 10/15 — cert-manager"
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

# ---------- 11. namespace + Certificate resources ----------
log "phase 11/15 — daytona-region namespace + Certificates"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat > "$STATE_DIR/certificates.yaml" <<EOF
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
kubectl apply -f "$STATE_DIR/certificates.yaml" >/dev/null
ok "Certificate resources requested"

(( PHASE >= 2 )) || { log "PHASE=$PHASE — stopping after region infra setup"; exit 0; }
(( PHASE >= 3 )) || { log "PHASE=$PHASE — stopping before helm install"; exit 0; }

# ---------- 12. helm install daytona-region ----------
log "phase 12/15 — helm install daytona-region"

# If we picked an existing region in phase 4.7, we need to pre-populate the
# chart's region-config secret BEFORE helm install. The chart's pre-install
# hook will then see the secret exists, log "Region already fully registered.
# Skipping.", and exit. The proxy + snapshot-manager deployments read their
# credentials from this secret.
if [[ "$PICKED_EXISTING_REGION" == "true" ]]; then
  log "  reusing existing region — regenerating credentials + pre-populating secret"

  # Make sure the namespace exists (helm would create it but we need it now)
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Regenerate proxy API key
  _resp_proxy="$(mktemp)"
  _http="$(curl -sS -o "$_resp_proxy" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions/$REGION_ID/regenerate-proxy-api-key" 2>/dev/null || echo 000)"
  if [[ ! "$_http" =~ ^(200|201|204)$ ]]; then
    head -c 300 "$_resp_proxy" >&2; echo >&2
    rm -f "$_resp_proxy"
    die "  failed to regenerate proxy API key for region $REGION_ID (HTTP $_http)"
  fi
  _proxy_api_key="$(jq -r '.proxyApiKey // .apiKey // empty' < "$_resp_proxy")"
  rm -f "$_resp_proxy"
  [[ -z "$_proxy_api_key" ]] && die "  empty proxy API key in regenerate response"

  # Regenerate snapshot-manager credentials
  _resp_sm="$(mktemp)"
  _http="$(curl -sS -o "$_resp_sm" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions/$REGION_ID/regenerate-snapshot-manager-credentials" 2>/dev/null || echo 000)"
  if [[ ! "$_http" =~ ^(200|201|204)$ ]]; then
    head -c 300 "$_resp_sm" >&2; echo >&2
    rm -f "$_resp_sm"
    die "  failed to regenerate snapshot manager credentials (HTTP $_http)"
  fi
  _sm_username="$(jq -r '.snapshotManagerUsername // .username // empty' < "$_resp_sm")"
  _sm_password="$(jq -r '.snapshotManagerPassword // .password // empty' < "$_resp_sm")"
  rm -f "$_resp_sm"
  [[ -z "$_sm_username" || -z "$_sm_password" ]] && die "  empty snapshot-manager credentials in regenerate response"

  # Write the secret. Using stringData (plain text values get base64-encoded
  # by k8s server-side; we never round-trip them through disk).
  # Labels match what the chart hook applies so our `kubectl get secret -l
  # app.kubernetes.io/component=region-config` query later still finds it.
  _secret_yaml="$(mktemp)"
  chmod 600 "$_secret_yaml"
  cat > "$_secret_yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $RELEASE-region-config
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/component: region-config
    app.kubernetes.io/instance: $RELEASE
    app.kubernetes.io/name: daytona-region
type: Opaque
stringData:
  id: "$REGION_ID"
  proxyApiKey: "$_proxy_api_key"
  snapshotManagerUsername: "$_sm_username"
  snapshotManagerPassword: "$_sm_password"
  sshGatewayApiKey: ""
EOF
  kubectl apply -f "$_secret_yaml" >/dev/null
  secure_rm "$_secret_yaml"
  unset _proxy_api_key _sm_username _sm_password
  ok "  pre-populated $RELEASE-region-config — chart's hook will skip registration"
fi

# Render values to a mktemp file that lives only in memory (tmpfs on Linux,
# /var/folders on macOS). Shred it as soon as helm finishes.
VALUES_TMP="$(mktemp -t daytona-region-values.XXXXXXXX.yaml)"
trap 'secure_rm "$VALUES_TMP" 2>/dev/null || true' EXIT INT TERM
chmod 600 "$VALUES_TMP"

# Read the HMAC values once, render into the template, immediately shred
# the in-memory variables. The values file itself is shredded when this
# script exits via the trap.
_hmac_access="$(gcloud secrets versions access latest --secret="$SECRET_HMAC_ACCESS" --project="$GCP_PROJECT")"
_hmac_secret="$(gcloud secrets versions access latest --secret="$SECRET_HMAC_SECRET" --project="$GCP_PROJECT")"
DOMAIN="$DOMAIN" \
REGION_NAME="$REGION_NAME" \
DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
GCS_LOCATION="$GCP_REGION" \
GCS_BUCKET="$GCS_BUCKET" \
HMAC_ACCESS_KEY="$_hmac_access" \
HMAC_SECRET_KEY="$_hmac_secret" \
  envsubst < "$SCRIPT_DIR/values-region.yaml.tmpl" > "$VALUES_TMP"
unset _hmac_access _hmac_secret

helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_TMP" \
  --timeout 10m >/dev/null
if [[ "$PICKED_EXISTING_REGION" == "true" ]]; then
  ok "helm install completed — registration hook skipped (region was reused)"
else
  ok "helm install completed — pre-install hook registered region '$REGION_NAME' with Daytona Cloud"
fi

# Shred the rendered values file immediately. The chart-managed k8s secret
# is the source of truth from here on.
secure_rm "$VALUES_TMP"
trap - EXIT INT TERM

log "  reading region credentials from the secret"
SECRET_NAME="$(kubectl -n "$NAMESPACE" get secret -l app.kubernetes.io/component=region-config -o name | head -1)"
[[ -n "$SECRET_NAME" ]] || SECRET_NAME="secret/$RELEASE-region-config"
REGION_ID_FROM_SECRET="$(kubectl -n "$NAMESPACE" get "$SECRET_NAME" -o jsonpath='{.data.id}' | base64 -d 2>/dev/null || true)"
if [[ -n "$REGION_ID_FROM_SECRET" ]]; then
  REGION_ID="$REGION_ID_FROM_SECRET"
fi
echo "$REGION_ID" > "$STATE_DIR/region-id.txt"
ok "region in use: id=$REGION_ID"

log "  waiting for proxy + snapshot-manager pods to be Ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance="$RELEASE" \
  --timeout=10m || warn "not all pods Ready; inspect: kubectl -n $NAMESPACE get pods"
ok "region services running"

# ---- 12.5  ingress annotations for large docker pushes / sandbox uploads ----
#
# ingress-nginx defaults to a 1 MiB `client_max_body_size`. Docker registry
# layer pushes (and any sandbox file upload over ~1 MB) blow that limit
# with HTTP 413 "Request Entity Too Large". The values template renders
# these annotations on a fresh helm install, but we ALSO apply them here
# via `kubectl annotate --overwrite` as a self-healing safety net:
#
#   (a) Existing deployments from older versions of this script don't
#       have the annotations baked in. A `helm upgrade` *should* add
#       them, but Helm has historical edge cases with annotation diffs
#       (e.g., when an annotation key existed but with a different value
#       in a previous render). The explicit kubectl patch is idempotent
#       and authoritative.
#
#   (b) If a future user manually edits the values file and forgets these
#       annotations, the script still keeps the deployment functional.
#
# We apply to BOTH the proxy and snapshot-manager ingresses. The proxy
# carries sandbox preview / SDK file-upload traffic; the snapshot-manager
# carries docker push traffic. Both can exceed 1 MiB.
log "phase 12.5/15 — ingress annotations (large-body + streaming + long timeouts)"
declare -a INGRESS_ANNOTATIONS=(
  "nginx.ingress.kubernetes.io/proxy-body-size=0"
  "nginx.ingress.kubernetes.io/proxy-request-buffering=off"
  "nginx.ingress.kubernetes.io/proxy-read-timeout=3600"
  "nginx.ingress.kubernetes.io/proxy-send-timeout=3600"
)
for ing in "${RELEASE}-proxy" "${RELEASE}-snapshot-manager"; do
  if ! kubectl -n "$NAMESPACE" get ingress "$ing" >/dev/null 2>&1; then
    warn "  ingress '$ing' not found in namespace $NAMESPACE — skipping (chart may not have created it)"
    continue
  fi
  if kubectl -n "$NAMESPACE" annotate ingress "$ing" \
       "${INGRESS_ANNOTATIONS[@]}" --overwrite >/dev/null 2>&1; then
    ok "  $ing: annotations applied"
  else
    warn "  $ing: annotate command returned non-zero (continuing)"
  fi
done

(( PHASE >= 4 )) || { log "PHASE=$PHASE — stopping after helm install"; exit 0; }

# ---------- 13. runner firewall + instance picker + GCE instances ----------
log "phase 13/15 — runner provisioning"

# --- 13a. firewall rules ---
log "  firewall: in-VPC traffic from GKE pods to runner ports 3000+2220"
# Source-tags are easier than CIDR-juggling; we tag both the GKE cluster's
# nodes (via the existing pool's network tag) and the runner VMs.
GKE_NODE_TAG="$(gcloud container clusters describe "$CLUSTER_NAME" "${GKE_LOCATION_FLAG[@]}" \
  --project "$GCP_PROJECT" --format='value(nodeConfig.tags[0])' 2>/dev/null || true)"
if [[ -z "$GKE_NODE_TAG" ]]; then
  # Older clusters store tags under nodePools[].config.tags
  GKE_NODE_TAG="$(gcloud container node-pools list --cluster "$CLUSTER_NAME" \
    "${GKE_LOCATION_FLAG[@]}" --project "$GCP_PROJECT" \
    --format='value(config.tags[0])' 2>/dev/null | head -1)"
fi
RUNNER_TAG="daytona-runner-${_hash}"
ok "  GKE node network tag: ${GKE_NODE_TAG:-<unknown>}   runner tag: $RUNNER_TAG"

# Create the runner ingress firewall rule if missing
if ! gcloud compute firewall-rules describe "$FW_RUNNER_INGRESS" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  # shellcheck disable=SC2054  # commas inside --rules=tcp:3000,tcp:2220 are not array separators
  fw_args=(
    --project="$GCP_PROJECT"
    --network="$GKE_NETWORK"
    --direction=INGRESS
    --action=ALLOW
    --rules=tcp:3000,tcp:2220
    --target-tags="$RUNNER_TAG"
  )
  if [[ -n "$GKE_NODE_TAG" ]]; then
    fw_args+=(--source-tags="$GKE_NODE_TAG")
  else
    # Fallback: limit to the cluster's pod CIDR
    PODS_CIDR="$(gcloud container clusters describe "$CLUSTER_NAME" "${GKE_LOCATION_FLAG[@]}" \
      --project "$GCP_PROJECT" --format='value(clusterIpv4Cidr)')"
    fw_args+=(--source-ranges="$PODS_CIDR")
  fi
  gcloud compute firewall-rules create "$FW_RUNNER_INGRESS" "${fw_args[@]}" --quiet >/dev/null
  ok "  firewall rule $FW_RUNNER_INGRESS created"
else
  ok "  firewall rule $FW_RUNNER_INGRESS already exists"
fi

# IAP TCP forwarding rule (allows our laptop -> runner:22 via gcloud ssh
# --tunnel-through-iap; the IAP source range 35.235.240.0/20 is fixed).
if ! gcloud compute firewall-rules describe "$FW_IAP_SSH" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FW_IAP_SSH" \
    --project="$GCP_PROJECT" \
    --network="$GKE_NETWORK" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags="$RUNNER_TAG" \
    --quiet >/dev/null
  ok "  firewall rule $FW_IAP_SSH created (IAP -> :22)"
else
  ok "  firewall rule $FW_IAP_SSH already exists"
fi

# --- 13b. SKU resolution: env var > previous-run state > interactive picker > default ---
#
# Priority order:
#   1. RUNNER_MACHINE_TYPE env var set by the caller — use as-is, skip picker
#   2. RUNNER_MACHINE_TYPE restored from .state/sku.env (re-run case) — use, skip picker
#   3. Interactive picker (only if neither above applies and NON_INTERACTIVE != true)
#   4. Hardcoded default n2-standard-8 (non-interactive fallback)
#
# In all cases, RUNNER_COUNT is then auto-clamped to whatever fits in the
# EFFECTIVE quota = min(regional CPUS free, global CPUS_ALL_REGIONS free).
# Minimum is MIN_RUNNER_COUNT (default 2) — if the quota can't even fit 2
# runners of the smallest viable SKU, we die with a quota-increase URL.
MIN_RUNNER_COUNT="${MIN_RUNNER_COUNT:-2}"

# Compute effective vCPU budget. GCP has two relevant quotas:
#   - CPUS              regional, lives on `gcloud compute regions describe`
#   - CPUS_ALL_REGIONS  global, lives on `gcloud compute project-info describe`
# Whichever is lower constrains how many runners can actually start.
log "  detecting vCPU quota (regional CPUS + global CPUS_ALL_REGIONS)"
region_quota_json="$(gcloud compute regions describe "$GCP_REGION" --project="$GCP_PROJECT" --format=json)"
proj_quota_json="$(gcloud compute project-info describe --project="$GCP_PROJECT" --format=json)"

# gcloud returns quota values as JSON floats (e.g. "limit": 32.0). Pipe
# through jq's `floor` so we get integers — bash arithmetic `(( ))` rejects
# decimals with "syntax error: invalid arithmetic operator". `floor` also
# safely handles null (treated as 0 by the `// 0` fallback first).
cpu_limit="$(echo  "$region_quota_json" | jq -r '.quotas[]? | select(.metric=="CPUS")            | (.limit // 0 | floor)')"
cpu_used="$(echo   "$region_quota_json" | jq -r '.quotas[]? | select(.metric=="CPUS")            | (.usage // 0 | floor)')"
gcpu_limit="$(echo "$proj_quota_json"   | jq -r '.quotas[]? | select(.metric=="CPUS_ALL_REGIONS") | (.limit // 0 | floor)')"
gcpu_used="$(echo  "$proj_quota_json"   | jq -r '.quotas[]? | select(.metric=="CPUS_ALL_REGIONS") | (.usage // 0 | floor)')"

# Belt-and-suspenders: ensure these are always integers even if jq returns
# empty (no matching quota row at all).
cpu_limit="${cpu_limit:-0}";   cpu_used="${cpu_used:-0}"
gcpu_limit="${gcpu_limit:-0}"; gcpu_used="${gcpu_used:-0}"

cpu_free=$(( cpu_limit  - cpu_used  ))
gcpu_free=$(( gcpu_limit - gcpu_used ))

# If CPUS_ALL_REGIONS isn't present at all (limit=0), treat global as
# unconstrained — the regional quota is the only binding limit.
if (( gcpu_limit > 0 )); then
  if (( cpu_free < gcpu_free )); then
    effective_free="$cpu_free"
  else
    effective_free="$gcpu_free"
  fi
  global_display="$gcpu_free"
else
  effective_free="$cpu_free"
  global_display="(unset — no CPUS_ALL_REGIONS quota on this project)"
fi

ok "    regional CPUS in $GCP_REGION: $cpu_used / $cpu_limit used → $cpu_free free"
ok "    global   CPUS_ALL_REGIONS    : $gcpu_used / $gcpu_limit used → $global_display free"
ok "    EFFECTIVE vCPU budget for runners: $effective_free"

# Candidate machine types. (vCPU, GiB) pairs. Order matters for the menu.
declare -a CANDIDATES=(
  "n2-standard-4  4  16"
  "n2-standard-8  8  32"
  "n2-standard-16 16 64"
  "c3-standard-8  8  32"
  "c3-standard-22 22 88"
  "c3-standard-44 44 176"
)

# Filter to candidates that fit at least MIN_RUNNER_COUNT runners
declare -a ELIGIBLE=()
for c in "${CANDIDATES[@]}"; do
  mcpu="$(echo "$c" | awk '{print $2}')"
  max_n="$(awk -v f="$effective_free" -v c="$mcpu" 'BEGIN{printf "%d", f/c}')"
  if (( max_n >= MIN_RUNNER_COUNT )); then
    ELIGIBLE+=("$c $max_n")
  fi
done

if [[ ${#ELIGIBLE[@]} -eq 0 ]]; then
  die "  No machine type can fit $MIN_RUNNER_COUNT runners within your quota.
        EFFECTIVE budget: $effective_free vCPU (min of regional + global)
        Smallest SKU we offer is n2-standard-4 at 4 vCPU, so you'd need >= $((MIN_RUNNER_COUNT * 4)) vCPU free.

        Request a quota increase here:
          https://console.cloud.google.com/iam-admin/quotas?project=$GCP_PROJECT
        Look for:
          - CPUS (regional, in $GCP_REGION) — currently $cpu_limit
          - CPUS_ALL_REGIONS (global)       — currently $gcpu_limit

        OR override the minimum with: MIN_RUNNER_COUNT=1 ./repro.sh"
fi

# Resolve the SKU
if [[ -n "$RUNNER_MACHINE_TYPE" ]]; then
  ok "  using RUNNER_MACHINE_TYPE=$RUNNER_MACHINE_TYPE (from env or previous run)"
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
  # Pick the smallest eligible default — biased toward something that fits
  RUNNER_MACHINE_TYPE="$(echo "${ELIGIBLE[0]}" | awk '{print $1}')"
  ok "  non-interactive: defaulting to $RUNNER_MACHINE_TYPE (smallest eligible)"
else
  echo
  echo "  Pick a runner machine type (only options that fit ≥$MIN_RUNNER_COUNT runners in quota shown):"
  echo "    #  machine          vCPU  RAM(GiB)   max-runners-in-quota"
  printf '    %s\n' "$(printf '%.0s-' {1..58})"
  default_choice=1
  for i in "${!ELIGIBLE[@]}"; do
    row="${ELIGIBLE[$i]}"
    mtype="$(echo "$row" | awk '{print $1}')"
    mcpu="$(echo  "$row" | awk '{print $2}')"
    mram="$(echo  "$row" | awk '{print $3}')"
    max_n="$(echo "$row" | awk '{print $4}')"
    # Default to n2-standard-8 if it's eligible
    [[ "$mtype" == "n2-standard-8" ]] && default_choice=$((i+1))
    printf '    %d  %-15s  %4d  %8d   %d\n' "$((i+1))" "$mtype" "$mcpu" "$mram" "$max_n"
  done
  echo
  default_mtype="$(echo "${ELIGIBLE[$((default_choice-1))]}" | awk '{print $1}')"
  read -r -p "  Choice (1-${#ELIGIBLE[@]}, default=$default_choice for $default_mtype): " ans
  ans="${ans:-$default_choice}"
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || (( ans < 1 || ans > ${#ELIGIBLE[@]} )); then
    die "invalid choice: $ans"
  fi
  RUNNER_MACHINE_TYPE="$(echo "${ELIGIBLE[$((ans-1))]}" | awk '{print $1}')"
fi

# Find the max_n for the resolved SKU
picked_vcpu=""
picked_max_n=""
for c in "${CANDIDATES[@]}"; do
  if [[ "$(echo "$c" | awk '{print $1}')" == "$RUNNER_MACHINE_TYPE" ]]; then
    picked_vcpu="$(echo "$c" | awk '{print $2}')"
    picked_max_n="$(awk -v f="$effective_free" -v c="$picked_vcpu" 'BEGIN{printf "%d", f/c}')"
    break
  fi
done
if [[ -z "$picked_vcpu" ]]; then
  # SKU not in our table (user-provided custom type) — best-effort fallback.
  # We can't compute max_n without knowing vCPU; assume RUNNER_COUNT requested fits.
  warn "  $RUNNER_MACHINE_TYPE is not in the built-in size table; skipping quota clamp."
  picked_max_n="$RUNNER_COUNT"
  picked_vcpu="?"
fi

# Auto-clamp RUNNER_COUNT to fit in the effective quota
if (( picked_max_n < MIN_RUNNER_COUNT )); then
  die "  ${RUNNER_MACHINE_TYPE} cannot fit $MIN_RUNNER_COUNT runners.
        max-fits in your current quota = $picked_max_n
        effective vCPU budget          = $effective_free
        SKU vCPU per instance          = $picked_vcpu

        Likely cause: $RUNNER_MACHINE_TYPE was chosen on a previous run
        (saved in $STATE_DIR/sku.env) but your global CPUS_ALL_REGIONS
        budget is now too low to use it. Recovery options:

          1. Pick a smaller SKU on the next run:
               rm $STATE_DIR/sku.env
               ./repro.sh
             (The picker will only show SKUs that fit your current quota.)

          2. Pin to a specific smaller SKU + count:
               RUNNER_MACHINE_TYPE=n2-standard-4 RUNNER_COUNT=$MIN_RUNNER_COUNT ./repro.sh

          3. Bypass the minimum (and accept 1-runner deployment):
               MIN_RUNNER_COUNT=1 ./repro.sh

          4. Request more quota:
               https://console.cloud.google.com/iam-admin/quotas?project=$GCP_PROJECT
             (target CPUS_ALL_REGIONS = 64+ for prod-shape)"
fi
if (( RUNNER_COUNT > picked_max_n )); then
  warn "  RUNNER_COUNT=$RUNNER_COUNT exceeds quota for $RUNNER_MACHINE_TYPE (max=$picked_max_n) — clamping to $picked_max_n"
  RUNNER_COUNT="$picked_max_n"
fi
if (( RUNNER_COUNT < MIN_RUNNER_COUNT )); then
  die "  RUNNER_COUNT=$RUNNER_COUNT is below MIN_RUNNER_COUNT=$MIN_RUNNER_COUNT.
        Increase quota or set MIN_RUNNER_COUNT=$RUNNER_COUNT explicitly."
fi
ok "  selected: $RUNNER_COUNT × $RUNNER_MACHINE_TYPE   (= $((RUNNER_COUNT * picked_vcpu)) vCPU; effective budget was $effective_free)"

# Compute sensible CUSTOM_CPU_COUNT / CUSTOM_MEMORY_GB defaults from the
# chosen SKU — but only fill in the ones the user hasn't already set
# (either via env or via sku.env restore).
if [[ -z "$CUSTOM_CPU_COUNT" || -z "$CUSTOM_MEMORY_GB" ]]; then
  case "$RUNNER_MACHINE_TYPE" in
    n2-standard-4|c3-standard-4)  _cpu=4;  _mem=12 ;;
    n2-standard-8|c3-standard-8)  _cpu=8;  _mem=28 ;;
    n2-standard-16)               _cpu=16; _mem=58 ;;
    c3-standard-22)               _cpu=22; _mem=80 ;;
    c3-standard-44)               _cpu=44; _mem=160 ;;
    *)                            _cpu=8;  _mem=28 ;;
  esac
  CUSTOM_CPU_COUNT="${CUSTOM_CPU_COUNT:-$_cpu}"
  CUSTOM_MEMORY_GB="${CUSTOM_MEMORY_GB:-$_mem}"
  unset _cpu _mem
fi
CUSTOM_DISK_GB="${CUSTOM_DISK_GB:-50}"
ok "  per-runner advertised capacity: $CUSTOM_CPU_COUNT vCPU / ${CUSTOM_MEMORY_GB} GiB / ${CUSTOM_DISK_GB} GiB disk"

# Persist the resolved values so phase 14 + re-runs use the same numbers.
{
  echo "RUNNER_MACHINE_TYPE=$RUNNER_MACHINE_TYPE"
  echo "RUNNER_COUNT=$RUNNER_COUNT"
  echo "CUSTOM_CPU_COUNT=$CUSTOM_CPU_COUNT"
  echo "CUSTOM_MEMORY_GB=$CUSTOM_MEMORY_GB"
  echo "CUSTOM_DISK_GB=$CUSTOM_DISK_GB"
} > "$STATE_DIR/sku.env"

# --- 13c. provision RUNNER_COUNT GCE instances ---
log "  creating $RUNNER_COUNT × $RUNNER_MACHINE_TYPE GCE instances in $GCP_ZONE"

# Use the latest Ubuntu 22.04 LTS minimal image (smaller, faster boot).
# Family alias: ubuntu-2204-lts; we resolve it to a stable image name to
# guarantee idempotency across runs.
#
# NB: gcloud will print a warning like
#   "Disk size: '100 GB' is larger than image size: '10 GB'."
# on every create. This is harmless — Ubuntu Cloud images include
# cloud-init+growpart and resize the root partition to fill the disk on
# first boot. By the time the runner-bootstrap.sh runs, /dev/sda1 is the
# full $RUNNER_DISK_GB. The warning cannot be suppressed via gcloud flags.
UBUNTU_IMAGE_FAMILY="ubuntu-2204-lts"
UBUNTU_IMAGE_PROJECT="ubuntu-os-cloud"

# Discover all zones in $GCP_REGION. ZONE_RESOURCE_POOL_EXHAUSTED is a
# transient GCP capacity issue affecting one zone at a time — we keep
# trying other zones in the region rather than failing the whole run.
# $GCP_ZONE is tried first (preferred), then the rest of the region.
declare -a CANDIDATE_ZONES=()
CANDIDATE_ZONES+=("$GCP_ZONE")
while IFS= read -r _z; do
  [[ -z "$_z" || "$_z" == "$GCP_ZONE" ]] && continue
  CANDIDATE_ZONES+=("$_z")
done < <(gcloud compute zones list --project="$GCP_PROJECT" \
           --filter="region:( $GCP_REGION )" \
           --format='value(name)' 2>/dev/null)
ok "  candidate zones for $RUNNER_MACHINE_TYPE: ${CANDIDATE_ZONES[*]}"

declare -a RUNNER_INSTANCE_NAMES=()
declare -a RUNNER_ZONES=()
for idx in $(seq 1 "$RUNNER_COUNT"); do
  rname="${RUNNER_NAME_PREFIX}-${idx}"

  # Idempotency: an instance from a previous run may exist in ANY zone of
  # the region, not just $GCP_ZONE. Look it up across all candidate zones.
  existing_zone=""
  for _z in "${CANDIDATE_ZONES[@]}"; do
    if gcloud compute instances describe "$rname" \
         --zone="$_z" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      existing_zone="$_z"
      break
    fi
  done
  if [[ -n "$existing_zone" ]]; then
    ok "    $rname already exists in zone $existing_zone"
    RUNNER_INSTANCE_NAMES+=("$rname")
    RUNNER_ZONES+=("$existing_zone")
    continue
  fi

  # Try to create, falling back across zones on ZONE_RESOURCE_POOL_EXHAUSTED
  # or "machine type not supported in this zone" errors. Any OTHER error
  # surfaces immediately (we don't want to mask quota issues, IAM problems,
  # bad SKU names, etc.).
  #
  # NB: gcloud will print a "Disk size: '100 GB' is larger than image size:
  # '10 GB'" warning on every successful create. We INTENTIONALLY do not
  # suppress this — runner-bootstrap.sh explicitly verifies via growpart +
  # resize2fs + `df -h /` on first boot.
  created_zone=""
  for _z in "${CANDIDATE_ZONES[@]}"; do
    log "    creating $rname in zone $_z"
    _err="$(mktemp)"
    if gcloud compute instances create "$rname" \
         --project="$GCP_PROJECT" \
         --zone="$_z" \
         --machine-type="$RUNNER_MACHINE_TYPE" \
         --image-family="$UBUNTU_IMAGE_FAMILY" \
         --image-project="$UBUNTU_IMAGE_PROJECT" \
         --boot-disk-size="${RUNNER_DISK_GB}GB" \
         --boot-disk-type="pd-balanced" \
         --network="$GKE_NETWORK" \
         --subnet="$GKE_SUBNET" \
         --tags="$RUNNER_TAG" \
         --service-account="$RUNNER_SA_EMAIL" \
         --scopes="https://www.googleapis.com/auth/cloud-platform" \
         --labels="$REGION_LABEL_KEY=$REGION_LABEL_VALUE,managed-by=gcs-repro" \
         --metadata="enable-oslogin=FALSE" \
         --quiet 2>"$_err"; then
      # Surface gcloud's normal warnings (e.g. "Disk size > image size")
      cat "$_err" >&2 || true
      rm -f "$_err"
      created_zone="$_z"
      ok "    $rname created in zone $_z"
      break
    fi
    # Check if this is a "try another zone" error
    if grep -qE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|UNSUPPORTED_OPERATION|machine type .* not available in zone' "$_err"; then
      warn "    zone $_z exhausted/unsupported for $RUNNER_MACHINE_TYPE — trying next zone"
      # Show a one-line excerpt so the user sees WHICH error
      head -c 200 "$_err" | sed 's/^/      /' >&2; echo >&2
      rm -f "$_err"
      continue
    fi
    # Some other error — surface it and bail
    cat "$_err" >&2
    rm -f "$_err"
    die "    create failed for non-quota/non-capacity reason — see above"
  done
  if [[ -z "$created_zone" ]]; then
    die "    every zone in $GCP_REGION is exhausted for $RUNNER_MACHINE_TYPE.
        Options:
          1. Wait 5-30 min and re-run (capacity is transient)
          2. Pick a different SKU: rm $STATE_DIR/sku.env && ./repro.sh
          3. Try a different region: GCP_REGION=us-east1 ./repro.sh"
  fi
  RUNNER_INSTANCE_NAMES+=("$rname")
  RUNNER_ZONES+=("$created_zone")
done

# Wait for SSH to come up via IAP. Each runner uses its OWN zone (which
# may differ from $GCP_ZONE if it got placed via the zone-fallback loop
# above).
log "  waiting for IAP SSH availability on each runner (~30s/runner)"
for i in "${!RUNNER_INSTANCE_NAMES[@]}"; do
  rname="${RUNNER_INSTANCE_NAMES[$i]}"
  rzone="${RUNNER_ZONES[$i]}"
  attempt=0
  while true; do
    if gcloud compute ssh "$rname" \
        --project="$GCP_PROJECT" --zone="$rzone" \
        --tunnel-through-iap \
        --ssh-flag="-q" \
        --command "echo READY" 2>/dev/null | grep -q READY; then
      ok "    $rname SSH ready (zone=$rzone)"
      break
    fi
    attempt=$((attempt + 1))
    (( attempt > 30 )) && { warn "    $rname still not SSH-ready after ~2 min — bootstrap may fail"; break; }
    printf '\r    %s waiting for SSH... %ds' "$rname" $((attempt * 5)) >&2; sleep 5
  done
  printf '\n' >&2
done

# Capture each runner's internal IP (used by the proxy to reach the runner)
# and external IP (used for the runner API endpoint registered with Daytona).
# Each describe uses the runner's own zone.
declare -a RUNNER_INTERNAL_IPS=()
declare -a RUNNER_EXTERNAL_IPS=()
for i in "${!RUNNER_INSTANCE_NAMES[@]}"; do
  rname="${RUNNER_INSTANCE_NAMES[$i]}"
  rzone="${RUNNER_ZONES[$i]}"
  internal_ip="$(gcloud compute instances describe "$rname" \
    --zone "$rzone" --project "$GCP_PROJECT" \
    --format='value(networkInterfaces[0].networkIP)')"
  external_ip="$(gcloud compute instances describe "$rname" \
    --zone "$rzone" --project "$GCP_PROJECT" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
  RUNNER_INTERNAL_IPS+=("$internal_ip")
  RUNNER_EXTERNAL_IPS+=("${external_ip:-$internal_ip}")
done

# Save runner state for teardown / re-runs. We deliberately avoid ${VAR@Q}
# (bash 4.4+) for macOS default-shell compatibility; printf %q is portable
# and produces the same shell-escaped output. RUNNER_ZONES is critical so
# downstream SSH / describe commands target the right zone for each
# runner (instances may have landed in different zones via fallback).
{
  printf 'RUNNER_INSTANCE_NAMES=('
  printf '%q ' "${RUNNER_INSTANCE_NAMES[@]}"
  printf ')\n'
  printf 'RUNNER_ZONES=('
  printf '%q ' "${RUNNER_ZONES[@]}"
  printf ')\n'
  printf 'RUNNER_INTERNAL_IPS=('
  printf '%q ' "${RUNNER_INTERNAL_IPS[@]}"
  printf ')\n'
  printf 'RUNNER_EXTERNAL_IPS=('
  printf '%q ' "${RUNNER_EXTERNAL_IPS[@]}"
  printf ')\n'
  echo "RUNNER_TAG=$RUNNER_TAG"
  echo "RUNNER_SA_EMAIL=$RUNNER_SA_EMAIL"
  echo "GCS_SA_EMAIL=$GCS_SA_EMAIL"
  echo "GCS_BUCKET=$GCS_BUCKET"
  echo "SECRET_HMAC_ACCESS=$SECRET_HMAC_ACCESS"
  echo "SECRET_HMAC_SECRET=$SECRET_HMAC_SECRET"
  echo "FW_RUNNER_INGRESS=$FW_RUNNER_INGRESS"
  echo "FW_IAP_SSH=$FW_IAP_SSH"
} > "$STATE_DIR/runners.env"

(( PHASE >= 5 )) || { log "PHASE=$PHASE — stopping after GCE provision"; exit 0; }

# ---------- 14. bootstrap each runner via IAP-SSH ----------
log "phase 14/15 — runner bootstrap via gcloud SSH (--tunnel-through-iap)"

# Determine the runner binary version that matches the Daytona API.
log "  determining Daytona runner binary version to install"
api_version="$(curl -sSI -H "Authorization: Bearer $DAYTONA_API_KEY" \
  "$DAYTONA_API_URL/regions" 2>/dev/null \
  | grep -i '^x-daytona-api-version:' | awk '{print $2}' | tr -d '\r\n ')"
if [[ -z "$api_version" || "$api_version" != v* ]]; then
  log "    no x-daytona-api-version header; falling back to GitHub latest"
  api_version="$(curl -fsSL https://api.github.com/repos/daytonaio/daytona/releases/latest \
    | jq -r '.tag_name // empty')"
fi
RUNNER_VERSION="${RUNNER_VERSION:-$api_version}"
[[ -z "$RUNNER_VERSION" ]] && die "could not determine RUNNER_VERSION"
RUNNER_BINARY_URL="https://github.com/daytonaio/daytona/releases/download/${RUNNER_VERSION}/runner-amd64"
ok "  runner binary: $RUNNER_VERSION  ($RUNNER_BINARY_URL)"

# install.sh wants the HOST ROOT (it appends /api/...) — strip the trailing /api
install_api_url="${DAYTONA_API_URL%/api}"
install_api_url="${install_api_url%/api/}"

# delete_runner_with_unschedule_fallback <runner-name> <runner-id>
#
# Tries to delete a Daytona Cloud runner via the API, with a fallback path
# for runners that the API refuses to delete in their current state.
#
# Strategy:
#   1. Plain DELETE /api/runners/{id}.
#      - 200/204/404 → success
#      - 400         → fallback to step 2 (most common: runner is
#                       schedulable + still has known sandboxes/state)
#      - anything else → fallback also, but log loudly
#   2. PATCH /api/runners/{id}/scheduling to flip schedulable=false.
#      Wait ~3s for Daytona Cloud's internal state to update.
#   3. Retry DELETE.
#
# Always prints the response body when a request fails (instead of
# swallowing it). Returns 0 if the runner is gone after this; non-zero
# means manual cleanup is required.
delete_runner_with_unschedule_fallback() {
  local rname="$1"
  local rid="$2"
  local body http

  log "    found existing runner '$rname' (id=$rid) — attempting DELETE"
  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners/$rid" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404)
      ok "    deleted existing runner (http=$http)"
      rm -f "$body"
      return 0
      ;;
    *)
      warn "    DELETE returned HTTP $http — response body:"
      head -c 800 "$body" | sed 's/^/      /' >&2; echo >&2
      ;;
  esac
  rm -f "$body"

  # Fallback: mark unschedulable, then retry DELETE
  log "    falling back: PATCH /scheduling to mark runner unschedulable, then retry DELETE"
  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X PATCH -H "Authorization: Bearer $DAYTONA_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"schedulable": false}' \
    "$DAYTONA_API_URL/runners/$rid/scheduling" 2>/dev/null || echo 000)"
  case "$http" in
    200|204)
      ok "    PATCH /scheduling succeeded (http=$http)"
      ;;
    *)
      warn "    PATCH /scheduling returned HTTP $http — response body:"
      head -c 400 "$body" | sed 's/^/      /' >&2; echo >&2
      ;;
  esac
  rm -f "$body"

  # Give Daytona Cloud's scheduler a moment to record the new state
  sleep 3

  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners/$rid" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404)
      ok "    deleted existing runner on retry (http=$http)"
      rm -f "$body"
      return 0
      ;;
    *)
      warn "    DELETE retry STILL failed with HTTP $http — response body:"
      head -c 800 "$body" | sed 's/^/      /' >&2; echo >&2
      rm -f "$body"
      return 1
      ;;
  esac
}

register_runner() {
  # Returns (on stdout): the name of the Secret Manager secret holding the
  # runner's dtn_xxx token. Status messages via log/ok/warn go to stderr
  # (so they don't pollute the captured stdout — see warn() definition).
  local rname="$1"
  local token_secret_name="daytona-${rname}-token"
  local id_file="$STATE_DIR/runner-id-${rname}.txt"
  local meta_file="$STATE_DIR/runner-meta-${rname}.env"

  # Idempotency: if the secret exists AND our local state has the matching
  # files, reuse silently. This handles the "PHASE=5 re-run" case where the
  # runner was already registered and we have a valid token in GSM.
  if gcloud secrets describe "$token_secret_name" --project="$GCP_PROJECT" >/dev/null 2>&1 \
     && [[ -f "$id_file" ]] && [[ -f "$meta_file" ]]; then
    log "    runner '$rname' already registered (state file + GSM secret intact); reusing"
    echo "$token_secret_name"
    return 0
  fi

  # Preflight: if a runner with this name already exists in Daytona Cloud
  # (e.g., from a previous run whose state was lost), DELETE it first.
  # This avoids the 409 conflict path and any race conditions around
  # delete-then-recreate propagation.
  #
  # Daytona's DELETE endpoint can return HTTP 400 if the runner is in a
  # state that disallows direct deletion (most commonly: it must be marked
  # unschedulable first). We try the simple DELETE, and if that 400's, we
  # PATCH .../scheduling to flip it unschedulable, wait briefly, and
  # retry the DELETE. If THAT also fails, we surface the response body
  # and direct the user to manual cleanup.
  log "    checking Daytona Cloud for existing runner named '$rname'"
  local existing_runners_file existing_id
  existing_runners_file="$(mktemp)"
  curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners" > "$existing_runners_file" 2>/dev/null || true
  existing_id="$(jq -r --arg n "$rname" '.[]? | select(.name==$n) | .id' \
    < "$existing_runners_file" 2>/dev/null | head -1 || true)"
  rm -f "$existing_runners_file"
  if [[ -n "$existing_id" ]]; then
    if ! delete_runner_with_unschedule_fallback "$rname" "$existing_id"; then
      warn "    could not delete runner '$rname' (id=$existing_id) via API"
      warn "    Manual cleanup required:"
      warn "      1. Visit https://app.daytona.io/dashboard/runners"
      warn "      2. Find the runner named '$rname'"
      warn "      3. Click the three-dot menu → Delete"
      warn "    Then re-run: PHASE=5 ./repro.sh"
      return 1
    fi
    # Brief pause for Daytona Cloud's view to settle before the new POST.
    sleep 2
  fi

  # Now POST a fresh registration
  log "    POST $DAYTONA_API_URL/runners  name=$rname  regionId=$REGION_ID"
  local http_code
  http_code="$(curl -sS --max-time 30 -o "$STATE_DIR/runner-reg-${rname}.json" -w '%{http_code}' \
    -X POST "$DAYTONA_API_URL/runners" \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$rname\",\"regionId\":\"$REGION_ID\"}" 2>/dev/null || echo 000)"

  if [[ ! "$http_code" =~ ^(200|201|204)$ ]]; then
    warn "    POST /runners failed for $rname (HTTP $http_code) — response body:"
    head -c 500 "$STATE_DIR/runner-reg-${rname}.json" >&2; echo >&2
    return 1
  fi

  local runner_id runner_token
  runner_id="$(jq -r '.id // empty' < "$STATE_DIR/runner-reg-${rname}.json")"
  runner_token="$(jq -r '.apiKey // empty' < "$STATE_DIR/runner-reg-${rname}.json")"
  if [[ -z "$runner_id" || -z "$runner_token" ]]; then
    warn "    /runners response missing id/apiKey:"
    cat "$STATE_DIR/runner-reg-${rname}.json" >&2; echo >&2
    return 1
  fi

  ok "    registered runner $rname (id=$runner_id, http=$http_code)"

  # Store the runner token in Secret Manager. The id (non-secret) we keep
  # locally for the teardown script.
  ensure_secret_with_value "$token_secret_name" "$runner_token"
  iam_bind_with_retry gcloud secrets add-iam-policy-binding "$token_secret_name" \
    --project="$GCP_PROJECT" \
    --member="serviceAccount:$RUNNER_SA_EMAIL" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --quiet \
    || { warn "    failed to grant secretAccessor on $token_secret_name"; return 1; }
  unset runner_token

  printf '%s' "$runner_id" > "$id_file"
  printf 'RUNNER_TOKEN_SECRET=%q\nRUNNER_ID=%q\n' "$token_secret_name" "$runner_id" > "$meta_file"

  # ONLY this line goes to stdout — it's the function's return value
  echo "$token_secret_name"
}

# Bootstrap each runner via IAP SSH. The payload is built per-runner with
# Secret Manager *resource names* baked in — the actual secret values are
# fetched inside the VM using the runner SA.
for i in "${!RUNNER_INSTANCE_NAMES[@]}"; do
  rname="${RUNNER_INSTANCE_NAMES[$i]}"
  rzone="${RUNNER_ZONES[$i]}"
  rext_ip="${RUNNER_EXTERNAL_IPS[$i]}"
  runner_api_url="http://${rext_ip}:3000"

  log "  bootstrapping $rname (zone=$rzone, external=$rext_ip)"

  if ! token_secret_name="$(register_runner "$rname")"; then
    warn "    skipping $rname (registration failed); rerun PHASE=5 to retry"
    continue
  fi
  ok "    registered with Daytona; token in secret '$token_secret_name'"

  # Build the SSH payload. Note: API_KEY ends up in the bootstrap script's
  # env *temporarily* — install.sh's config fetch needs it. It's NOT baked
  # into the systemd unit file (only API_TOKEN = the runner token from
  # Secret Manager is).
  payload_file="$(mktemp -t daytona-runner-payload.XXXXXXXX.sh)"
  chmod 600 "$payload_file"
  trap 'secure_rm "$payload_file" 2>/dev/null || true' EXIT INT TERM
  {
    echo "#!/usr/bin/env bash"
    echo "set -euo pipefail"
    echo "export API_URL=\"$install_api_url\""
    echo "export API_KEY=\"$DAYTONA_API_KEY\""
    echo "export RUNNER_API_URL=\"$runner_api_url\""
    echo "export REGION=\"$REGION_NAME\""
    echo "export DOMAIN_OR_IP=\"$rext_ip\""
    echo "export PUBLIC_IP=\"$rext_ip\""
    echo "export PROCEED=\"y\""
    echo "export CONFIRM=\"y\""
    echo "export CAPACITY=\"1000\""
    echo "export CUSTOM_CPU_COUNT=\"$CUSTOM_CPU_COUNT\""
    echo "export CUSTOM_MEMORY_GB=\"$CUSTOM_MEMORY_GB\""
    echo "export CUSTOM_DISK_GB=\"$CUSTOM_DISK_GB\""
    echo "export AWS_REGION=\"$GCP_REGION\""
    echo "export AWS_DEFAULT_BUCKET=\"$GCS_BUCKET\""
    echo "export AWS_ENDPOINT_URL=\"https://storage.googleapis.com\""
    echo "export GCP_PROJECT=\"$GCP_PROJECT\""
    echo "export SECRET_HMAC_ACCESS=\"$SECRET_HMAC_ACCESS\""
    echo "export SECRET_HMAC_SECRET=\"$SECRET_HMAC_SECRET\""
    echo "export SECRET_RUNNER_TOKEN=\"$token_secret_name\""
    echo "export RUNNER_BINARY_URL=\"$RUNNER_BINARY_URL\""
    echo ""
    cat "$SCRIPT_DIR/runner-bootstrap.sh"
  } > "$payload_file"

  # Send the payload via IAP SSH. Three important details:
  #
  #   (1) Use `sudo bash -s` (NOT plain `bash -s`). Unlike AWS SSM which
  #       runs as root by default, `gcloud compute ssh` connects as your
  #       OS Login user. The bootstrap needs root for apt, /tmp/* writes
  #       owned by root, /opt/daytona-runner, /etc/systemd, docker daemon,
  #       sysbox install, etc. Running the whole script under sudo is the
  #       cleanest fix — internal `sudo` calls become harmless redundancy.
  #
  #   (2) `bash -s` reads the script from stdin. We redirect from
  #       $payload_file so the script body never appears on a command line
  #       (gcloud logs commands; stdin contents are not logged).
  #
  #   (3) --ssh-flag="-q" suppresses gcloud/SSH's own non-essential
  #       chatter (banners, motd) so the bootstrap output reads cleanly.
  if gcloud compute ssh "$rname" \
       --project="$GCP_PROJECT" --zone="$rzone" \
       --tunnel-through-iap \
       --ssh-flag="-q" \
       --command 'sudo bash -s' \
       < "$payload_file"; then
    ok "    bootstrap completed for $rname"
  else
    warn "    bootstrap returned non-zero for $rname (rerun PHASE=5 to retry just this one)"
  fi

  secure_rm "$payload_file"
  trap - EXIT INT TERM
done

log "  giving runners ~30s to call home + report Ready"
sleep 30
runner_resp="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" || true)"
echo "$runner_resp" \
  | jq -r --arg p "$RUNNER_NAME_PREFIX" --arg r "$REGION_ID" \
    '.[] | select((.name | startswith($p)) or ((.region // {}).id == $r) or (.regionId == $r))
           | {id, name, state, score: .availabilityScore}' 2>/dev/null \
  || warn "could not parse /runners response — check curl output manually"

# ---------- 14.5 wait for TLS certificates to be Ready ----------
log "phase 14.5/15 — waiting for TLS certificates to be Ready"
wait_for_cert() {
  local cert="$1"
  local first_timeout="${2:-180}"
  local retry_timeout="${3:-180}"
  if kubectl -n "$NAMESPACE" wait --for=condition=Ready certificate/"$cert" --timeout="${first_timeout}s" >/dev/null 2>&1; then
    ok "  $cert Ready"
    return 0
  fi
  warn "  $cert not Ready after ${first_timeout}s — resetting (LE finalize race or backoff)"
  kubectl -n "$NAMESPACE" describe certificate "$cert" 2>&1 \
    | grep -E '^  (Message|Reason|Last Failure):' | head -6 | sed 's/^/      /' || true
  kubectl -n "$NAMESPACE" delete certificate "$cert" --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" delete challenge --all >/dev/null 2>&1 || true
  sleep 3
  kubectl apply -f "$STATE_DIR/certificates.yaml" >/dev/null
  if kubectl -n "$NAMESPACE" wait --for=condition=Ready certificate/"$cert" --timeout="${retry_timeout}s" >/dev/null 2>&1; then
    ok "  $cert Ready (after reset)"
    return 0
  fi
  warn "  $cert STILL not Ready after reset — inspect with:"
  warn "    kubectl -n $NAMESPACE describe certificate $cert"
  warn "    kubectl -n $NAMESPACE get certificaterequests,orders,challenges"
  return 1
}
wait_for_cert proxy-wildcard-cert 180 180 || true
wait_for_cert snapshots-cert      120 120 || true

# ---------- 15. e2e: SDK sandbox creation in our region ----------
if [[ "$SKIP_E2E" == "true" ]]; then
  log "phase 15/15 — SKIP_E2E=true, skipping SDK validation"
else
  log "phase 15/15 — e2e SDK validation in region $REGION_NAME"
  echo "    Two stages run:"
  echo "      Stage A — public-image sandbox (proves proxy + runner basic path)"
  echo "      Stage B — declarative builder (proves GCS wiring works on both sides)"
  echo
  if DAYTONA_API_URL="$DAYTONA_API_URL" \
     DAYTONA_API_KEY="$DAYTONA_API_KEY" \
     REGION_NAME="$REGION_NAME" \
     STAGING="$STAGING" \
     GCS_BUCKET="$GCS_BUCKET" \
     GCP_PROJECT="$GCP_PROJECT" \
       bash "$SCRIPT_DIR/e2e.sh"; then
    ok "e2e SDK validation: all stages passed"
  else
    warn "e2e SDK validation reported issues — see the receipt above"
  fi
fi

# ---------- summary ----------
echo
echo "======================================================================"
echo "  BYOC DEPLOYMENT COMPLETE (GCP)"
echo "======================================================================"
echo "  Daytona Cloud region        : $REGION_NAME (id: $REGION_ID)"
echo "  Region proxy                : https://proxy.$DOMAIN"
echo "  Snapshot manager            : https://snapshots.$DOMAIN"
echo "  GCS bucket                  : gs://$GCS_BUCKET ($GCP_REGION)"
echo "  Snapshot SA (HMAC owner)    : $GCS_SA_EMAIL"
echo "  Runner SA                   : $RUNNER_SA_EMAIL"
echo "  GKE cluster                 : $CLUSTER_NAME ($GCP_REGION)"
echo "  Ingress LB IP               : $LB_IP"
echo "  Runners                     : $RUNNER_COUNT × $RUNNER_MACHINE_TYPE"
for i in "${!RUNNER_INSTANCE_NAMES[@]}"; do
  echo "      - ${RUNNER_INSTANCE_NAMES[$i]}  zone=${RUNNER_ZONES[$i]}  internal=${RUNNER_INTERNAL_IPS[$i]}  external=${RUNNER_EXTERNAL_IPS[$i]}"
done
echo
echo "  Secret Manager (no values, just names):"
echo "    $SECRET_HMAC_ACCESS  $SECRET_HMAC_SECRET"
for i in "${!RUNNER_INSTANCE_NAMES[@]}"; do
  echo "    daytona-${RUNNER_INSTANCE_NAMES[$i]}-token"
done
echo
echo "  SDK usage (target the region by name):"
echo "    daytona = Daytona(DaytonaConfig(api_key='...', target='$REGION_NAME'))"
echo "    sandbox = daytona.create()"
echo
echo "  Inspect:"
echo "    kubectl -n $NAMESPACE get pods,svc,ingress,certificate"
echo "    gcloud compute instances list --filter='labels.daytona-region=$REGION_NAME' \\"
echo "        --format='table(name,zone,machineType.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'"
echo "    gcloud compute ssh ${RUNNER_INSTANCE_NAMES[0]} --tunnel-through-iap --zone ${RUNNER_ZONES[0]}"
echo "    curl -H \"Authorization: Bearer \$DAYTONA_API_KEY\" $DAYTONA_API_URL/runners | jq"
echo
echo "  Teardown: $SCRIPT_DIR/teardown.sh"
echo "======================================================================"
