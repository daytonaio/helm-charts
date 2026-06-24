#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC (GCP) — Artifact Registry (GAR) setup for Daytona Cloud
# private-registry auth.
# =============================================================================
#
# Provisions everything needed to register a private Google Container /
# Artifact Registry as a Docker credential in Daytona Cloud, so sandboxes
# in your BYOC region can pull private images from your GCP project.
#
# What this creates:
#   1. Artifact Registry (Docker format) repository in $GCP_REGION
#   2. A dedicated, minimal-privilege service account
#   3. roles/artifactregistry.reader binding scoped to ONLY this repo
#   4. A JSON service-account key, stored in Google Secret Manager
#      (never written to disk in cleartext; printed on stdout once below)
#
# What you paste into Daytona Cloud:
#   - https://app.daytona.io/dashboard/registries  →  "Add Registry"
#       Registry URL:    <location>-docker.pkg.dev
#       Username:        _json_key             (literal string)
#       Password:        <the JSON key contents printed by this script>
#       Project ID:      $GCP_PROJECT
#
# Note: as of 2024, classic gcr.io was deprecated for new projects. This
# script uses Artifact Registry (*.pkg.dev). Daytona's "GCR" registry
# form accepts both formats — only the hostname differs.
#
# Security:
#   - The JSON key is the only long-lived credential. It's stored in
#     Secret Manager (encrypted at rest, accessible only via IAM) and
#     never written to .state/ as plaintext. The script DOES print it
#     to stdout once on first creation so you can copy-paste into the
#     Daytona dashboard. Use --show-key to re-print it later from
#     Secret Manager without rotating.
#   - The service account has the absolute minimum needed:
#     roles/artifactregistry.reader scoped to ONE repository in ONE
#     region. It cannot list other repos, push, or modify anything.
#   - Rotate the key by running this script with --rotate-key. The old
#     key is deleted from IAM; the new one is stored in Secret Manager
#     and printed once.
#
# Required env:
#   GCP_PROJECT             your GCP project ID
#
# Optional env:
#   GCP_REGION              default us-central1 (or whatever repro.sh used)
#   GAR_REPO_NAME           default daytona-images
#   GAR_SA_ID               default dt-gar-<8charhash>
#
# Usage:
#   ./gcr-setup.sh                  # provision + print credentials once
#   ./gcr-setup.sh --show-key       # re-print the existing key (no rotate)
#   ./gcr-setup.sh --rotate-key     # delete the old key, mint + print a new one
#   ./gcr-setup.sh --dry-run        # show what would be created
#   ./gcr-setup.sh --teardown       # delete everything (or use ../teardown.sh)
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2 ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" >&2 ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" >&2 ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

# ---- args ----
SHOW_KEY_ONLY=false
ROTATE_KEY=false
DRY_RUN=false
TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --show-key)     SHOW_KEY_ONLY=true ;;
    --rotate-key)   ROTATE_KEY=true ;;
    --dry-run|-n)   DRY_RUN=true ;;
    --teardown)     TEARDOWN=true ;;
    -h|--help)
      awk '/^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# ---- config ----
GCP_PROJECT="${GCP_PROJECT:?GCP_PROJECT env var is required}"
GCP_REGION="${GCP_REGION:-us-central1}"
GAR_REPO_NAME="${GAR_REPO_NAME:-daytona-images}"
NAMESPACE="${NAMESPACE:-daytona-region}"   # (unused; kept for consistency)

# Stable SA id derived from project+region (so re-runs land on the same SA)
_gar_hash="$(printf '%s/%s/%s' "$GCP_PROJECT" "$GCP_REGION" "$GAR_REPO_NAME" | shasum | cut -c1-8)"
GAR_SA_ID="${GAR_SA_ID:-dt-gar-${_gar_hash}}"
GAR_SA_EMAIL="${GAR_SA_ID}@${GCP_PROJECT}.iam.gserviceaccount.com"
GAR_SECRET_NAME="${GAR_SECRET_NAME:-daytona-gar-${_gar_hash}-json-key}"

# Derived
REGISTRY_HOST="${GCP_REGION}-docker.pkg.dev"
REGISTRY_FULL_PATH="${REGISTRY_HOST}/${GCP_PROJECT}/${GAR_REPO_NAME}"

command -v gcloud >/dev/null 2>&1 || die "gcloud not on PATH"
command -v jq     >/dev/null 2>&1 || die "jq not on PATH"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  [dry-run] '; printf '%q ' "$@"; printf '\n' >&2
    return 0
  fi
  "$@"
}

# ---- teardown mode ----
if [[ "$TEARDOWN" == "true" ]]; then
  log "GAR teardown"
  if gcloud secrets describe "$GAR_SECRET_NAME" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    run gcloud secrets delete "$GAR_SECRET_NAME" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 \
      && ok "deleted secret $GAR_SECRET_NAME"
  fi
  if gcloud iam service-accounts describe "$GAR_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    # Delete all keys first
    for kid in $(gcloud iam service-accounts keys list \
                   --iam-account="$GAR_SA_EMAIL" --project="$GCP_PROJECT" \
                   --managed-by=user --format='value(name)' 2>/dev/null \
                 | awk -F/ '{print $NF}'); do
      [[ -z "$kid" ]] && continue
      run gcloud iam service-accounts keys delete "$kid" \
        --iam-account="$GAR_SA_EMAIL" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    done
    run gcloud iam service-accounts delete "$GAR_SA_EMAIL" --project="$GCP_PROJECT" --quiet >/dev/null \
      && ok "deleted service account $GAR_SA_EMAIL"
  fi
  if gcloud artifacts repositories describe "$GAR_REPO_NAME" \
       --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    run gcloud artifacts repositories delete "$GAR_REPO_NAME" \
      --location="$GCP_REGION" --project="$GCP_PROJECT" --quiet >/dev/null \
      && ok "deleted Artifact Registry $GAR_REPO_NAME in $GCP_REGION"
  fi
  ok "GAR teardown complete"
  exit 0
fi

# ---- show-key mode (just reprint existing) ----
if [[ "$SHOW_KEY_ONLY" == "true" ]]; then
  log "retrieving existing JSON key from Secret Manager"
  if ! gcloud secrets describe "$GAR_SECRET_NAME" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    die "no existing key in Secret Manager (run without --show-key first to provision)"
  fi
  json_key="$(gcloud secrets versions access latest --secret="$GAR_SECRET_NAME" --project="$GCP_PROJECT")"
  echo
  echo "============================================================"
  echo "  DAYTONA REGISTRY CONFIGURATION — paste these into the"
  echo "  Daytona dashboard at https://app.daytona.io/dashboard/registries"
  echo "============================================================"
  echo
  echo "  Registry URL    : $REGISTRY_HOST"
  echo "  Project ID      : $GCP_PROJECT"
  echo "  Username        : _json_key"
  echo "  Password / Key  : (the entire JSON below, INCLUDING braces)"
  echo
  echo "  Repository path (use this for image references in sandboxes):"
  echo "      $REGISTRY_FULL_PATH/<image>:<tag>"
  echo
  echo "------ JSON KEY BEGIN ------"
  echo "$json_key"
  echo "------ JSON KEY END --------"
  echo
  exit 0
fi

# ---- ensure required APIs ----
log "ensuring Artifact Registry API is enabled"
run gcloud services enable artifactregistry.googleapis.com iam.googleapis.com iamcredentials.googleapis.com secretmanager.googleapis.com \
  --project="$GCP_PROJECT" --quiet >/dev/null
ok "APIs enabled"

# ---- create the GAR repository ----
log "Artifact Registry repository: $REGISTRY_FULL_PATH"
if gcloud artifacts repositories describe "$GAR_REPO_NAME" \
     --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "  repository already exists"
else
  run gcloud artifacts repositories create "$GAR_REPO_NAME" \
    --project="$GCP_PROJECT" \
    --location="$GCP_REGION" \
    --repository-format=docker \
    --description="Daytona BYOC private images" \
    --quiet >/dev/null
  ok "  repository created (format=docker, location=$GCP_REGION)"
fi

# ---- create the dedicated service account ----
log "service account: $GAR_SA_EMAIL"
if gcloud iam service-accounts describe "$GAR_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "  service account already exists"
else
  run gcloud iam service-accounts create "$GAR_SA_ID" \
    --project="$GCP_PROJECT" \
    --display-name="Daytona Cloud pull-only access to $GAR_REPO_NAME" \
    --description="Used by Daytona Cloud to pull private images from $REGISTRY_FULL_PATH" \
    --quiet >/dev/null
  ok "  service account created"
  log "  waiting for IAM to propagate the new SA"
  attempt=0
  while (( attempt < 30 )); do
    if gcloud iam service-accounts describe "$GAR_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
fi

# ---- grant least-priv reader on the specific repo ----
log "granting roles/artifactregistry.reader scoped to $GAR_REPO_NAME"
# Use add-iam-policy-binding on the repository (NOT project) — this scopes
# the read permission to one repo, not the entire project's registries.
attempts=0
until run gcloud artifacts repositories add-iam-policy-binding "$GAR_REPO_NAME" \
        --location="$GCP_REGION" --project="$GCP_PROJECT" \
        --member="serviceAccount:$GAR_SA_EMAIL" \
        --role="roles/artifactregistry.reader" \
        --condition=None \
        --quiet >/dev/null 2>&1
do
  attempts=$((attempts + 1))
  if (( attempts > 20 )); then
    die "  IAM binding failed after ~60s — check that the SA exists + permissions propagated"
  fi
  printf '\r    waiting for SA to propagate (%ds)' $((attempts * 3)) >&2; sleep 3
done
printf '\n' >&2
ok "  reader role bound (scoped to this repository only)"

# ---- mint a JSON key (or reuse existing one) ----
log "JSON key for $GAR_SA_EMAIL"
ensure_secret_with_value() {
  # ensure_secret_with_value <name> <value-on-stdin>
  local name="$1"
  if gcloud secrets describe "$name" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    gcloud secrets versions add "$name" --project="$GCP_PROJECT" --data-file=- --quiet >/dev/null
  else
    gcloud secrets create "$name" --project="$GCP_PROJECT" \
      --replication-policy=automatic \
      --labels="managed-by=gcs-repro,kind=gar-json-key" \
      --quiet >/dev/null
    gcloud secrets versions add "$name" --project="$GCP_PROJECT" --data-file=- --quiet >/dev/null
  fi
}

JSON_KEY_PRINTED=false
if [[ "$ROTATE_KEY" == "true" ]] || ! gcloud secrets describe "$GAR_SECRET_NAME" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  if [[ "$ROTATE_KEY" == "true" ]]; then
    log "  --rotate-key: deleting all existing keys for $GAR_SA_EMAIL"
    for kid in $(gcloud iam service-accounts keys list \
                   --iam-account="$GAR_SA_EMAIL" --project="$GCP_PROJECT" \
                   --managed-by=user --format='value(name)' 2>/dev/null \
                 | awk -F/ '{print $NF}'); do
      [[ -z "$kid" ]] && continue
      run gcloud iam service-accounts keys delete "$kid" \
        --iam-account="$GAR_SA_EMAIL" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    done
  fi

  log "  minting new JSON key"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] gcloud iam service-accounts keys create /tmp/...  --iam-account=$GAR_SA_EMAIL" >&2
    echo "  [dry-run] (would store in Secret Manager as $GAR_SECRET_NAME)" >&2
    NEW_JSON_KEY='{"...": "dry-run placeholder"}'
  else
    # gcloud keys create writes to a file — use a tmpfile we shred after
    tmp_key="$(mktemp)"
    chmod 600 "$tmp_key"
    gcloud iam service-accounts keys create "$tmp_key" \
      --iam-account="$GAR_SA_EMAIL" --project="$GCP_PROJECT" --quiet >/dev/null
    NEW_JSON_KEY="$(cat "$tmp_key")"
    # Shred + remove
    if command -v shred >/dev/null 2>&1; then
      shred -u -z -n 1 "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
    elif command -v gshred >/dev/null 2>&1; then
      gshred -u -z -n 1 "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
    else
      rm -f "$tmp_key"
    fi
    # Store in Secret Manager
    printf '%s' "$NEW_JSON_KEY" | ensure_secret_with_value "$GAR_SECRET_NAME"
  fi
  ok "  JSON key created + stored in Secret Manager ($GAR_SECRET_NAME)"
  JSON_KEY_PRINTED=true
else
  ok "  reusing existing JSON key from Secret Manager ($GAR_SECRET_NAME)"
  NEW_JSON_KEY="$(gcloud secrets versions access latest --secret="$GAR_SECRET_NAME" --project="$GCP_PROJECT")"
fi

# ---- output ----
echo
echo "============================================================"
echo "  DAYTONA REGISTRY CONFIGURATION"
echo "============================================================"
echo "  Paste these into https://app.daytona.io/dashboard/registries"
echo "  → 'Add Registry'"
echo
echo "  Registry URL    : $REGISTRY_HOST"
echo "  Project ID      : $GCP_PROJECT"
echo "  Username        : _json_key"
echo "  Password / Key  : (the entire JSON below, including braces)"
echo
echo "  Image references in sandboxes use the form:"
echo "      $REGISTRY_FULL_PATH/<image>:<tag>"
echo
echo "  Push a test image (one-time, on your workstation):"
echo "      gcloud auth configure-docker $REGISTRY_HOST --quiet"
echo "      docker pull alpine:3.21"
echo "      docker tag alpine:3.21 $REGISTRY_FULL_PATH/test-alpine:latest"
echo "      docker push $REGISTRY_FULL_PATH/test-alpine:latest"
echo
if [[ "$JSON_KEY_PRINTED" == "true" ]]; then
  echo "  ⚠  The JSON KEY below is printed only on first creation (or"
  echo "     with --show-key / --rotate-key). Copy it now — to retrieve"
  echo "     it later without rotating, run:"
  echo "         ./gcr-setup.sh --show-key"
  echo
  echo "------ JSON KEY BEGIN ------"
  echo "$NEW_JSON_KEY"
  echo "------ JSON KEY END --------"
  echo
fi
echo "  Cleanup later: ./gcr-setup.sh --teardown"
echo "  (Or ../teardown.sh — picks this up via labels automatically.)"
echo "============================================================"

# Don't leave the JSON sitting in our env
unset NEW_JSON_KEY
