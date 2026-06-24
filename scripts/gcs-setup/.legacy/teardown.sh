#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC (GCP) — teardown
# =============================================================================
# Nukes every BYOC-related resource in $GCP_PROJECT, regardless of whether
# the local .state/ directory still knows about it. Discovery is by:
#
#   - Names matching our deterministic patterns:
#       GKE clusters       daytona-byoc-gke-*
#       GCE instances      gke-runner-*  (and any with labels.managed-by=gcs-repro)
#       GCS buckets        gke-byoc-*-snapshots
#       Service accounts   dt-snap-*, dt-runner-*
#       Secret Manager     daytona-*   (and any with labels.managed-by=gcs-repro)
#       Firewall rules     *-runner-ingress, *-iap-ssh
#       Daytona regions    gke-byoc-*
#       Daytona runners    gke-runner-*  (and any attached to a BYOC region)
#
#   - Labels: anything with labels.managed-by=gcs-repro (always swept)
#
# This makes teardown idempotent and safe to run repeatedly. It will also
# clean up leftovers from previous failed runs whose state was lost.
#
# Things that CANNOT be cleaned up programmatically (script reminds you):
#   - Personal Daytona API keys (rotate at app.daytona.io/dashboard/keys)
#
# Usage:
#   ./teardown.sh                    # interactive confirmation
#   ./teardown.sh --force            # skip prompt
#   ./teardown.sh --dry-run          # list what would be deleted, change nothing
#   ./teardown.sh --keep-cloudflare  # don't touch Cloudflare DNS records
#
# Required env (some are optional but used when present):
#   GCP_PROJECT                      (required)
#   DAYTONA_API_KEY                  (recommended — cleans up Daytona Cloud)
#   DOMAIN, CLOUDFLARE_API_TOKEN     (recommended — cleans up Cloudflare DNS)
#   GCP_REGION                       (default us-central1)
# =============================================================================

set -uo pipefail   # NOT -e — we want to plow through best-effort

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DOMAIN="${DOMAIN:-}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
NAMESPACE="${NAMESPACE:-daytona-region}"
RELEASE="${RELEASE:-daytona-region}"
STATE_DIR="$SCRIPT_DIR/.state"

FORCE=false
DRY_RUN=false
KEEP_CLOUDFLARE=false
for arg in "$@"; do
  case "$arg" in
    --force|-f)         FORCE=true ;;
    --dry-run|-n)       DRY_RUN=true ;;
    --keep-cloudflare)  KEEP_CLOUDFLARE=true ;;
    -h|--help)
      awk '
        /^#!/ { next }
        /^#/  { sub(/^# ?/, ""); print; next }
        { exit }
      ' "$0"
      exit 0 ;;
    *) die "unknown arg: $arg" ;;
  esac
done

[[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT env var is required"
command -v gcloud  >/dev/null 2>&1 || die "gcloud not on PATH"
command -v jq      >/dev/null 2>&1 || die "jq not on PATH"
command -v curl    >/dev/null 2>&1 || die "curl not on PATH"

# Suppress paginated output everywhere
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# ---------- helper: run a command, respecting --dry-run ----------
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  [dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# Treat a missing-resource error as success (idempotency).
# Usage: ok_or_warn "label" gcloud ... delete
ok_or_warn() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    warn "$label (failed or already gone)"
  fi
}

# Delete a Daytona Cloud runner robustly: tries plain DELETE, then if that
# returns 400 (or any other non-success code), PATCHes scheduling to
# unschedulable=true and retries. Prints the response body on every
# non-success so we can SEE what Daytona is complaining about instead of
# silently passing along a status code.
#
# Returns 0 if the runner is gone after this call; non-zero otherwise.
delete_daytona_runner() {
  local rname="$1"
  local rid="$2"
  local body http

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] DELETE $DAYTONA_API_URL/runners/$rid  ($rname)"
    return 0
  fi

  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners/$rid" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404)
      ok "    deleted runner $rname  id=$rid  http=$http"
      rm -f "$body"
      return 0
      ;;
    *)
      warn "    DELETE $rname returned HTTP $http — response body:"
      head -c 400 "$body" | sed 's/^/      /' >&2; echo >&2
      ;;
  esac
  rm -f "$body"

  # Fallback: mark unschedulable, then retry DELETE.
  log "    fallback: PATCH .../scheduling unschedulable, then retry DELETE"
  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X PATCH -H "Authorization: Bearer $DAYTONA_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"schedulable": false}' \
    "$DAYTONA_API_URL/runners/$rid/scheduling" 2>/dev/null || echo 000)"
  if [[ ! "$http" =~ ^(200|204)$ ]]; then
    warn "    PATCH /scheduling returned HTTP $http — body:"
    head -c 400 "$body" | sed 's/^/      /' >&2; echo >&2
  fi
  rm -f "$body"
  sleep 3

  body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners/$rid" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404)
      ok "    deleted runner $rname on retry  id=$rid  http=$http"
      rm -f "$body"
      return 0
      ;;
    *)
      warn "    DELETE retry STILL failed for $rname (http=$http) — body:"
      head -c 400 "$body" | sed 's/^/      /' >&2; echo >&2
      warn "    Manual cleanup: visit https://app.daytona.io/dashboard/runners and delete '$rname' there"
      rm -f "$body"
      return 1
      ;;
  esac
}

# ---- 1. Daytona Cloud cleanup (runners + regions) ----
# We always do this FIRST so the region delete on Daytona's side doesn't
# get stuck on "runners still attached". Two phases:
#   (a) list runners, delete any whose name starts with gke-runner-
#       OR whose regionId points at a BYOC-managed region
#   (b) list regions, delete any whose name starts with gke-byoc-

daytona_cloud_cleanup() {
  if [[ -z "$DAYTONA_API_KEY" ]]; then
    warn "no DAYTONA_API_KEY in env — skipping Daytona Cloud cleanup"
    warn "  (regions + runners will leak; clean up manually at app.daytona.io/dashboard)"
    return 0
  fi

  log "Daytona Cloud: discovering BYOC regions + runners"
  local regions_json runners_json byoc_region_ids byoc_runner_ids
  regions_json="$(curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions" 2>/dev/null || echo '[]')"
  runners_json="$(curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners" 2>/dev/null || echo '[]')"

  byoc_region_ids="$(echo "$regions_json" | jq -r '.[]? | select((.name // "") | startswith("gke-byoc-")) | .id')"
  byoc_runner_ids="$(echo "$runners_json" | jq -r --argjson regions "$regions_json" '
    .[]? |
    . as $r |
    select(
      (($r.name // "") | startswith("gke-runner-")) or
      (
        ($r.regionId // ($r.region // {}).id) as $rid |
        ($regions | map(select((.name // "") | startswith("gke-byoc-")) | .id) | index($rid))
      )
    ) | .id
  ')"

  # Delete runners first
  if [[ -n "$byoc_runner_ids" ]]; then
    log "  deleting BYOC runners from Daytona Cloud:"
    local count=0
    while IFS= read -r rid; do
      [[ -z "$rid" ]] && continue
      local rname
      rname="$(echo "$runners_json" | jq -r --arg i "$rid" '.[]? | select(.id == $i) | .name // "?"')"
      delete_daytona_runner "$rname" "$rid" || true
      count=$((count + 1))
    done <<< "$byoc_runner_ids"
    ok "  $count runners processed"
  else
    ok "  no BYOC runners to delete"
  fi

  # Brief pause for Daytona Cloud to reflect the runner deletions
  [[ "$DRY_RUN" != "true" ]] && sleep 2

  # Delete regions
  if [[ -n "$byoc_region_ids" ]]; then
    log "  deleting BYOC regions from Daytona Cloud:"
    local count=0
    while IFS= read -r rid; do
      [[ -z "$rid" ]] && continue
      local rname http
      rname="$(echo "$regions_json" | jq -r --arg i "$rid" '.[]? | select(.id == $i) | .name // "?"')"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [dry-run] DELETE $DAYTONA_API_URL/regions/$rid  ($rname)"
      else
        http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
          -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
          "$DAYTONA_API_URL/regions/$rid" 2>/dev/null || echo 000)"
        case "$http" in
          200|204|404) ok "    deleted region $rname  id=$rid  http=$http" ;;
          *)           warn "    region delete failed: $rname  id=$rid  http=$http (delete in dashboard)" ;;
        esac
      fi
      count=$((count + 1))
    done <<< "$byoc_region_ids"
    ok "  $count regions processed"
  else
    ok "  no BYOC regions to delete"
  fi
}

# ---- 2. helm uninstall best-effort (in case the cluster still exists) ----
helm_uninstall_best_effort() {
  command -v helm    >/dev/null 2>&1 || return 0
  command -v kubectl >/dev/null 2>&1 || return 0

  log "helm: uninstalling releases (best-effort)"
  if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    run helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || true
  fi
  run helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || true
  run helm uninstall cert-manager  -n cert-manager  >/dev/null 2>&1 || true
  ok "  helm uninstall complete (errors silenced; cluster may be gone already)"
}

# ---- 3. GCE instances (standalone runner VMs — NOT GKE node VMs) ----
gce_instances_cleanup() {
  log "GCE: discovering BYOC runner instances project-wide"
  local list
  # Catch: anything named gke-runner-*  OR  any instance with our labels.
  list="$(gcloud compute instances list --project="$GCP_PROJECT" \
    --filter='(name ~ "^gke-runner-") OR (labels.managed-by="gcs-repro")' \
    --format='value(name,zone)' 2>/dev/null || true)"

  if [[ -z "$list" ]]; then
    ok "  no runner instances found"
    return 0
  fi

  while IFS=$'\t' read -r name zone; do
    [[ -z "$name" ]] && continue
    zone="$(basename "$zone")"
    if run gcloud compute instances delete "$name" \
         --project="$GCP_PROJECT" --zone="$zone" --quiet >/dev/null 2>&1; then
      ok "  deleted instance $name (zone=$zone)"
    else
      warn "  delete failed for instance $name (zone=$zone)"
    fi
  done <<< "$list"
}

# ---- 4. GKE clusters (this also nukes the GKE-managed node VMs in MIGs) ----
gke_clusters_cleanup() {
  log "GKE: discovering BYOC clusters project-wide"
  # gcloud container clusters list with --filter doesn't accept name patterns
  # well across all gcloud versions, so we list all and grep.
  local clusters
  clusters="$(gcloud container clusters list --project="$GCP_PROJECT" \
    --format='value(name,location)' 2>/dev/null || true)"

  if [[ -z "$clusters" ]]; then
    ok "  no GKE clusters found"
    return 0
  fi

  local any=false
  while IFS=$'\t' read -r name location; do
    [[ -z "$name" ]] && continue
    case "$name" in daytona-byoc-gke-*) ;; *) continue ;; esac
    any=true
    log "  deleting GKE cluster $name (location=$location) — this also deletes its node VMs and load balancers"
    # `location` works for both regional + zonal clusters.
    if run gcloud container clusters delete "$name" \
         --project="$GCP_PROJECT" --location="$location" --quiet 2>/dev/null; then
      ok "  deleted $name"
    else
      warn "  delete failed for $name"
    fi
  done <<< "$clusters"
  [[ "$any" == "false" ]] && ok "  no daytona-byoc-gke-* clusters found"
}

# ---- 5. Firewall rules ----
firewall_rules_cleanup() {
  log "VPC: discovering BYOC firewall rules"
  local rules
  rules="$(gcloud compute firewall-rules list --project="$GCP_PROJECT" \
    --filter='(name ~ "-(runner-ingress|iap-ssh)$") OR (name ~ "^gke-byoc-")' \
    --format='value(name)' 2>/dev/null || true)"

  if [[ -z "$rules" ]]; then
    ok "  no matching firewall rules"
    return 0
  fi

  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    # Skip GKE-internal firewall rules (they're managed by the GKE cluster
    # delete, and we may have already deleted the cluster).
    case "$rule" in gke-*-master|gke-*-vms|gke-*-all|gke-*-ssh) continue ;; esac
    if run gcloud compute firewall-rules delete "$rule" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
      ok "  deleted firewall rule $rule"
    else
      warn "  delete failed for firewall rule $rule"
    fi
  done <<< "$rules"
}

# ---- 6. GCS buckets ----
gcs_buckets_cleanup() {
  log "GCS: discovering BYOC snapshot buckets"
  # gcloud storage buckets list returns gs://name URLs
  local buckets
  buckets="$(gcloud storage buckets list --project="$GCP_PROJECT" \
    --format='value(name)' 2>/dev/null \
    | sed 's|^gs://||;s|/$||' \
    | grep -E '^gke-byoc-.*-snapshots$' || true)"

  if [[ -z "$buckets" ]]; then
    ok "  no BYOC buckets found"
    return 0
  fi

  while IFS= read -r bucket; do
    [[ -z "$bucket" ]] && continue
    log "  emptying + deleting gs://$bucket"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] gcloud storage rm -r gs://$bucket/** --project=$GCP_PROJECT"
      echo "    [dry-run] gcloud storage buckets delete gs://$bucket --project=$GCP_PROJECT --quiet"
    else
      gcloud storage rm -r "gs://$bucket/**" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
      if gcloud storage buckets delete "gs://$bucket" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
        ok "    deleted gs://$bucket"
      else
        warn "    delete failed for gs://$bucket (may have versioned objects or holds)"
      fi
    fi
  done <<< "$buckets"
}

# ---- 6b. Artifact Registry repositories ----
# Only present if gcr-setup.sh was run. Looks for repos labelled by
# convention OR named by the gcr-setup.sh default. Safe to run when no
# repos exist.
gar_repos_cleanup() {
  log "Artifact Registry: discovering BYOC repositories"
  local repos
  # The default repo name from gcr-setup.sh is 'daytona-images'. We also
  # accept any repo with label managed-by=gcs-repro for forward-compat.
  repos="$(gcloud artifacts repositories list --project="$GCP_PROJECT" \
    --format='value(name,location)' 2>/dev/null | \
    awk -F/ '/\/repositories\/daytona-images$|\/repositories\/daytona-/ {print $NF "\t" $(NF-2)}' || true)"

  if [[ -z "$repos" ]]; then
    ok "  no BYOC GAR repositories found"
    return 0
  fi

  while IFS=$'\t' read -r rname rloc; do
    [[ -z "$rname" ]] && continue
    if run gcloud artifacts repositories delete "$rname" \
         --location="$rloc" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
      ok "  deleted $rname (location=$rloc)"
    else
      warn "  delete failed for $rname (location=$rloc)"
    fi
  done <<< "$repos"
}

# ---- 7. HMAC keys (must deactivate before delete) ----
hmac_keys_cleanup() {
  log "GCS: discovering HMAC keys for BYOC service accounts"
  local keys
  # List ALL HMAC keys in the project; filter to ones belonging to our SAs.
  keys="$(gcloud storage hmac list --project="$GCP_PROJECT" \
    --format='value(accessId,serviceAccountEmail)' 2>/dev/null || true)"

  if [[ -z "$keys" ]]; then
    ok "  no HMAC keys found"
    return 0
  fi

  local count=0
  while IFS=$'\t' read -r access_id sa_email; do
    [[ -z "$access_id" ]] && continue
    case "$sa_email" in dt-snap-*|dt-runner-*) ;; *)
      # Not one of ours — leave it alone
      continue ;;
    esac
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] gcloud storage hmac update $access_id --deactivate --project=$GCP_PROJECT"
      echo "  [dry-run] gcloud storage hmac delete $access_id --project=$GCP_PROJECT"
    else
      gcloud storage hmac update "$access_id" --deactivate --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
      if gcloud storage hmac delete "$access_id" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
        ok "  deleted HMAC key $access_id (sa=$sa_email)"
        count=$((count + 1))
      else
        warn "  delete failed for HMAC $access_id"
      fi
    fi
  done <<< "$keys"
  (( count == 0 )) && ok "  no BYOC HMAC keys to delete"
}

# ---- 8. Service accounts ----
service_accounts_cleanup() {
  log "IAM: discovering BYOC service accounts"
  # Includes:
  #   dt-snap-*    snapshot-manager bucket access (HMAC owner)
  #   dt-runner-*  runner VM identity (Secret Manager accessor)
  #   dt-gar-*     Daytona Cloud private-registry pull-only SA
  #                (created by gcr-setup.sh — only present if that
  #                 script was run; harmless to look for either way)
  local accts
  accts="$(gcloud iam service-accounts list --project="$GCP_PROJECT" \
    --filter='email ~ "^(dt-snap|dt-runner|dt-gar)-"' \
    --format='value(email)' 2>/dev/null || true)"

  if [[ -z "$accts" ]]; then
    ok "  no BYOC service accounts found"
    return 0
  fi

  while IFS= read -r sa; do
    [[ -z "$sa" ]] && continue
    # Delete user-managed keys for the SA before deleting the SA itself
    # (especially relevant for dt-gar-* which holds a JSON key).
    for kid in $(gcloud iam service-accounts keys list \
                   --iam-account="$sa" --project="$GCP_PROJECT" \
                   --managed-by=user --format='value(name)' 2>/dev/null \
                 | awk -F/ '{print $NF}'); do
      [[ -z "$kid" ]] && continue
      run gcloud iam service-accounts keys delete "$kid" \
        --iam-account="$sa" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    done
    if run gcloud iam service-accounts delete "$sa" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
      ok "  deleted $sa"
    else
      warn "  delete failed for $sa"
    fi
  done <<< "$accts"
}

# ---- 9. Secret Manager secrets ----
secrets_cleanup() {
  log "Secret Manager: discovering BYOC secrets"
  # We use name-based discovery (anything starting with "daytona-") and
  # ALSO label-based for belt-and-suspenders.
  local secrets
  secrets="$(gcloud secrets list --project="$GCP_PROJECT" \
    --format='value(name)' 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^daytona-' || true)"

  # Also pick up label-matches not caught by the name pattern
  local label_secrets
  label_secrets="$(gcloud secrets list --project="$GCP_PROJECT" \
    --filter='labels.managed-by="gcs-repro"' \
    --format='value(name)' 2>/dev/null \
    | awk -F/ '{print $NF}' || true)"

  # Merge + dedup
  local all_secrets
  all_secrets="$(printf '%s\n%s\n' "$secrets" "$label_secrets" | awk 'NF && !seen[$0]++')"

  if [[ -z "$all_secrets" ]]; then
    ok "  no BYOC secrets found"
    return 0
  fi

  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if run gcloud secrets delete "$s" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
      ok "  deleted secret $s"
    else
      warn "  delete failed for secret $s"
    fi
  done <<< "$all_secrets"
}

# ---- 10. Cloudflare A records ----
cloudflare_cleanup() {
  if [[ "$KEEP_CLOUDFLARE" == "true" ]]; then
    log "Cloudflare: skipping (--keep-cloudflare)"
    return 0
  fi
  if [[ -z "$DOMAIN" || -z "$CLOUDFLARE_API_TOKEN" ]]; then
    warn "DOMAIN or CLOUDFLARE_API_TOKEN missing — skipping Cloudflare cleanup"
    return 0
  fi

  log "Cloudflare: removing BYOC DNS records for $DOMAIN"
  local CF_API="https://api.cloudflare.com/client/v4"
  local CF_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")
  local candidate="$DOMAIN" zone_id=""
  while [[ "$candidate" == *.* ]]; do
    local id
    id="$(curl -sS --max-time 30 "${CF_AUTH[@]}" "$CF_API/zones?name=$candidate" | jq -r '.result[0].id // empty')"
    [[ -n "$id" ]] && { zone_id="$id"; break; }
    candidate="${candidate#*.}"
  done
  if [[ -z "$zone_id" ]]; then
    warn "  could not find Cloudflare zone for $DOMAIN"
    return 0
  fi
  for fqdn in "proxy.$DOMAIN" "*.proxy.$DOMAIN" "snapshots.$DOMAIN"; do
    local existing
    existing="$(curl -sS --max-time 30 "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records?name=$fqdn" | jq -r '.result[].id')"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] DELETE Cloudflare DNS $fqdn (record id=$id)"
      else
        curl -sS --max-time 30 -X DELETE "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records/$id" >/dev/null \
          && ok "  deleted $fqdn" || warn "  delete failed for $fqdn"
      fi
    done <<< "$existing"
  done
}

# ---- 11. Local state + kubeconfig contexts ----
local_state_cleanup() {
  log "local: removing state directory + kubeconfig contexts"
  if [[ -d "$STATE_DIR" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] rm -rf $STATE_DIR"
    else
      rm -rf "$STATE_DIR"
      ok "  removed $STATE_DIR"
    fi
  fi
  if command -v kubectl >/dev/null 2>&1; then
    # Find any kubeconfig contexts named gke_<project>_<loc>_daytona-byoc-gke-*
    kubectl config get-contexts -o name 2>/dev/null \
      | grep -E "^gke_${GCP_PROJECT}_.*_daytona-byoc-gke-" \
      | while read -r ctx; do
          run kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
        done
    kubectl config get-clusters 2>/dev/null \
      | grep -E "^gke_${GCP_PROJECT}_.*_daytona-byoc-gke-" \
      | while read -r cl; do
          run kubectl config delete-cluster "$cl" >/dev/null 2>&1 || true
        done
  fi
  ok "  local cleanup done"
}

# ---- Inventory pass (for the confirmation prompt) ----
inventory() {
  echo "  About to delete the following from project '$GCP_PROJECT':"
  echo

  local n
  n="$(gcloud container clusters list --project="$GCP_PROJECT" --format='value(name)' 2>/dev/null \
      | grep -c '^daytona-byoc-gke-' || true)"
  echo "    GKE clusters         : $n  (daytona-byoc-gke-*)"

  n="$(gcloud compute instances list --project="$GCP_PROJECT" \
      --filter='(name ~ "^gke-runner-") OR (labels.managed-by="gcs-repro")' \
      --format='value(name)' 2>/dev/null | grep -c . || true)"
  echo "    Runner VMs           : $n  (gke-runner-* and managed-by=gcs-repro)"

  n="$(gcloud compute firewall-rules list --project="$GCP_PROJECT" \
      --filter='(name ~ "-(runner-ingress|iap-ssh)$") OR (name ~ "^gke-byoc-")' \
      --format='value(name)' 2>/dev/null | grep -vcE '^gke-[^-]+-(master|vms|all|ssh)$' || true)"
  echo "    Firewall rules       : $n"

  n="$(gcloud storage buckets list --project="$GCP_PROJECT" --format='value(name)' 2>/dev/null \
      | sed 's|^gs://||;s|/$||' | grep -cE '^gke-byoc-.*-snapshots$' || true)"
  echo "    GCS buckets          : $n  (gke-byoc-*-snapshots)"

  n="$(gcloud artifacts repositories list --project="$GCP_PROJECT" \
      --format='value(name)' 2>/dev/null \
      | awk -F/ '{print $NF}' | grep -cE '^daytona-' || true)"
  echo "    Artifact Registry    : $n  (from gcr-setup.sh, daytona-*)"

  n="$(gcloud iam service-accounts list --project="$GCP_PROJECT" \
      --filter='email ~ "^(dt-snap|dt-runner|dt-gar)-"' --format='value(email)' 2>/dev/null | grep -c . || true)"
  echo "    Service accounts     : $n  (dt-snap-*, dt-runner-*, dt-gar-*)"

  n="$(gcloud secrets list --project="$GCP_PROJECT" --format='value(name)' 2>/dev/null \
      | awk -F/ '{print $NF}' | grep -cE '^daytona-' || true)"
  echo "    Secret Manager       : $n  (daytona-*, includes GAR JSON keys)"

  # Daytona Cloud counts
  if [[ -n "$DAYTONA_API_KEY" ]]; then
    local regions_json runners_json rn_count rg_count
    regions_json="$(curl -sS --max-time 15 -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/regions" 2>/dev/null || echo '[]')"
    runners_json="$(curl -sS --max-time 15 -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" 2>/dev/null || echo '[]')"
    rg_count="$(echo "$regions_json" | jq '[.[]? | select((.name // "") | startswith("gke-byoc-"))] | length')"
    rn_count="$(echo "$runners_json" | jq '[.[]? | select((.name // "") | startswith("gke-runner-"))] | length')"
    echo "    Daytona regions      : $rg_count  (gke-byoc-* in Daytona Cloud)"
    echo "    Daytona runners      : $rn_count  (gke-runner-* in Daytona Cloud)"
  else
    echo "    Daytona Cloud        : (DAYTONA_API_KEY not set — won't clean up)"
  fi

  if [[ -n "$DOMAIN" && -n "$CLOUDFLARE_API_TOKEN" && "$KEEP_CLOUDFLARE" != "true" ]]; then
    echo "    Cloudflare DNS       : proxy.$DOMAIN, *.proxy.$DOMAIN, snapshots.$DOMAIN"
  fi
  echo "    Local state          : $STATE_DIR"
  echo
}

# ---- Main ----
inventory
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  (dry-run — nothing will be executed)"
  echo
elif [[ "$FORCE" != "true" ]]; then
  read -r -p "  Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]] || die "aborted"
fi

# Order matters:
#   1. Daytona Cloud first (runners then regions) so region-delete isn't blocked
#   2. helm uninstall (best-effort, may already be moot if cluster is gone)
#   3. Standalone GCE VMs (the runner VMs we created — direct delete works)
#   4. GKE clusters (this kills GKE-managed node VMs that we can't delete directly)
#   5. Firewall rules (separately, since GKE owns its own and we don't touch those)
#   6. GCS buckets (must be empty first — emptied internally)
#   7. HMAC keys (deactivate then delete — required before deleting the owning SA)
#   8. Service accounts
#   9. Secret Manager secrets
#  10. Cloudflare DNS
#  11. Local state + kubeconfig
daytona_cloud_cleanup
helm_uninstall_best_effort
gce_instances_cleanup
gke_clusters_cleanup
firewall_rules_cleanup
gcs_buckets_cleanup
gar_repos_cleanup
hmac_keys_cleanup
service_accounts_cleanup
secrets_cleanup
cloudflare_cleanup
local_state_cleanup

echo
echo "  Teardown complete."
echo
echo "  Verify with:"
echo "    gcloud container clusters list --project=$GCP_PROJECT --filter='name~daytona-byoc-gke-'"
echo "    gcloud compute instances list  --project=$GCP_PROJECT --filter='(name~^gke-runner-) OR (labels.managed-by=gcs-repro)'"
echo "    gcloud storage buckets list    --project=$GCP_PROJECT --filter='name~^gke-byoc-.*-snapshots\$'"
echo "    gcloud artifacts repositories list --project=$GCP_PROJECT --filter='name~daytona-'"
echo "    gcloud iam service-accounts list --project=$GCP_PROJECT --filter='email~^(dt-snap|dt-runner|dt-gar)-'"
echo "    gcloud secrets list            --project=$GCP_PROJECT --filter='name~daytona-'"
echo "    gcloud compute firewall-rules list --project=$GCP_PROJECT --filter='name~^gke-byoc-'"
echo
echo "  Cannot be undone programmatically (rotate manually if you're done testing):"
echo "    - Personal Daytona API keys at https://app.daytona.io/dashboard/keys"
