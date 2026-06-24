#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC setup (AWS) - teardown
# =============================================================================
# Cleans up in the right order:
#   1. Delete the runners from Daytona Cloud
#   2. Delete the region from Daytona Cloud
#   3. helm uninstall daytona-region (so the in-cluster proxy NLB isn't
#      reused; ingress-nginx is left for the next step to clean up)
#   4. Terminate EC2 runner instances
#   5. Delete runner security group + IAM role/instance-profile
#   6. eksctl delete cluster (also removes the EKS-managed NLB and VPC,
#      assuming eksctl created the VPC)
#   7. Empty + delete S3 bucket
#   8. Delete IAM user + keys + inline policy
#   9. Delete Cloudflare CNAME records
#   10. Local state
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
DOMAIN="${DOMAIN:-}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
AWS_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="$AWS_REGION"
NAMESPACE="${NAMESPACE:-daytona-region}"
RELEASE="${RELEASE:-daytona-region}"
STATE_DIR="$SCRIPT_DIR/.state"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# Recover state from .state if available
REGION_NAME="${REGION_NAME:-}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-}"
REGION_ID=""
RUNNER_INSTANCE_IDS=()
RUNNER_NAMES=()
RUNNER_SG=""
IAM_ACCESS_KEY=""
IAM_SECRET_KEY=""
# ECR (private-registry verification) state — set if ecr-setup.sh ran
ECR_PULLER_ROLE_NAME=""
ECR_CACHE_PREFIX=""
DAYTONA_REGISTRY_ID=""
DAYTONA_REGISTRY_ENDPOINT=""

[[ -f "$STATE_DIR/names.env" ]] && source "$STATE_DIR/names.env"
[[ -f "$STATE_DIR/region-id.txt" ]] && REGION_ID="$(cat "$STATE_DIR/region-id.txt")"
[[ -f "$STATE_DIR/runners.env" ]] && source "$STATE_DIR/runners.env"
[[ -f "$STATE_DIR/iam-keys.env" ]] && source "$STATE_DIR/iam-keys.env"
[[ -f "$STATE_DIR/ecr.env" ]] && source "$STATE_DIR/ecr.env"

# Resource names derived the same way as repro.sh
if [[ -z "$REGION_NAME" ]]; then
  if [[ -n "$DOMAIN" ]]; then
    _hash="$(printf '%s' "$DOMAIN" | shasum | cut -c1-6)"
    CLUSTER_NAME="${CLUSTER_NAME:-daytona-byoc-aws-$_hash}"
  fi
  warn "no state — won't be able to clean up Daytona Cloud region/runner records"
else
  _hash="$(printf '%s' "$DOMAIN" | shasum | cut -c1-6)"
  CLUSTER_NAME="${CLUSTER_NAME:-daytona-byoc-aws-$_hash}"
  S3_BUCKET="${S3_BUCKET:-${REGION_NAME}-snapshots}"
  S3_BUCKET="$(printf '%s' "$S3_BUCKET" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"
  IAM_USER_NAME="${IAM_USER_NAME:-${REGION_NAME}-s3}"
  IAM_USER_NAME="$(printf '%s' "$IAM_USER_NAME" | cut -c1-64)"
  SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-${REGION_NAME}-runner-sg}"
  RUNNER_IAM_ROLE_NAME="${RUNNER_IAM_ROLE_NAME:-${REGION_NAME}-runner-role}"
  RUNNER_IAM_ROLE_NAME="$(printf '%s' "$RUNNER_IAM_ROLE_NAME" | cut -c1-64)"
  RUNNER_INSTANCE_PROFILE="$RUNNER_IAM_ROLE_NAME"
fi

echo
echo "  About to delete:"
[[ -n "$REGION_NAME" ]] && echo "    - Daytona Cloud region: $REGION_NAME${REGION_ID:+ (id: $REGION_ID)}"
[[ ${#RUNNER_NAMES[@]} -gt 0 ]] && echo "    - Daytona Cloud runners: ${RUNNER_NAMES[*]}"
[[ -n "${CLUSTER_NAME:-}" ]] && echo "    - EKS cluster: $CLUSTER_NAME ($AWS_REGION)"
[[ ${#RUNNER_INSTANCE_IDS[@]} -gt 0 ]] && echo "    - EC2 instances: ${RUNNER_INSTANCE_IDS[*]}"
[[ -n "${S3_BUCKET:-}" ]] && echo "    - S3 bucket: $S3_BUCKET (contents will be deleted)"
[[ -n "${IAM_USER_NAME:-}" ]] && echo "    - IAM user: $IAM_USER_NAME"
[[ -n "${RUNNER_IAM_ROLE_NAME:-}" ]] && echo "    - IAM role + instance profile: $RUNNER_IAM_ROLE_NAME"
[[ -n "${ECR_PULLER_ROLE_NAME:-}" ]] && echo "    - ECR puller IAM role: $ECR_PULLER_ROLE_NAME"
[[ -n "${DAYTONA_REGISTRY_ID:-}" ]] && echo "    - Daytona ECR registry registration: $DAYTONA_REGISTRY_ID"
[[ -n "${ECR_CACHE_PREFIX:-}" ]] && echo "    - ECR pull-through cache rule + cached repos: prefix '$ECR_CACHE_PREFIX'"
[[ -n "$DOMAIN" ]] && echo "    - Cloudflare CNAMEs: proxy.$DOMAIN, *.proxy.$DOMAIN, snapshots.$DOMAIN"
echo "    - Local state: $STATE_DIR"
echo

if [[ "$FORCE" != "true" ]]; then
  read -r -p "  Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]] || die "aborted"
fi

# ---- 1. delete runners from Daytona Cloud ----
#
# Three matchers run in order:
#   (1) exact name from .state/runners.env  - the most reliable; uses the
#       names we created in this run.
#   (2) name prefix                          - safety net if state was lost
#       but DOMAIN-derived prefix is intact.
#   (3) region id match (both old & new API shapes — Daytona changed the
#       /runners response between versions; current versions appear to have
#       moved .region.id to .regionId or similar, so we accept either).
#
# IDs are deduplicated across matchers so we don't issue redundant DELETEs.
# Each delete tolerates 404 (already gone). The region delete will return
# HTTP 400 if any runner is still attached — most often this means a
# matcher above didn't recognise the runner. The warning tells you which
# region to clean up by hand in the dashboard.
if [[ -n "$DAYTONA_API_KEY" ]]; then
  log "deleting runner(s) from Daytona Cloud"
  runners_json="$(curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" 2>/dev/null || echo '[]')"

  # macOS ships bash 3.2 which lacks associative arrays (`declare -A`), so
  # we accumulate candidates as `<id>\t<label>` lines in a temp file and
  # dedup by ID with `awk '!seen[$1]++'`. Same effect as a map[id]->label
  # but compatible with the default macOS shell.
  _candidates="$(mktemp)"

  # Matcher 1: exact name match using runners we created this run
  if [[ ${#RUNNER_NAMES[@]} -gt 0 ]]; then
    for rname in "${RUNNER_NAMES[@]}"; do
      rid="$(echo "$runners_json" | jq -r --arg n "$rname" '.[]? | select(.name == $n) | .id // empty' 2>/dev/null | head -1)"
      [[ -n "$rid" ]] && printf '%s\t%s (exact name)\n' "$rid" "$rname" >> "$_candidates"
    done
  fi

  # Matcher 2: name prefix
  if [[ -n "$RUNNER_NAME_PREFIX" ]]; then
    echo "$runners_json" \
      | jq -r --arg p "$RUNNER_NAME_PREFIX" \
          '.[]? | select(.name | startswith($p)) | "\(.id)\t\(.name) (prefix)"' 2>/dev/null \
      >> "$_candidates"
  fi

  # Matcher 3: region id (handle both old `.region.id` and new `.regionId`)
  if [[ -n "$REGION_ID" ]]; then
    echo "$runners_json" \
      | jq -r --arg r "$REGION_ID" \
          '.[]? | select(((.region // {}).id == $r) or (.regionId == $r)) | "\(.id)\t\(.name // "?") (region)"' 2>/dev/null \
      >> "$_candidates"
  fi

  # Dedup by ID (first column), keeping the first label seen for each ID
  _unique="$(awk -F'\t' 'NF>=2 && !seen[$1]++' "$_candidates")"
  rm -f "$_candidates"

  if [[ -z "$_unique" ]]; then
    ok "no matching runners found in Daytona Cloud — nothing to delete"
  else
    while IFS=$'\t' read -r rid label; do
      [[ -z "$rid" ]] && continue
      http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
        -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$DAYTONA_API_URL/runners/$rid" 2>/dev/null || echo 000)"
      case "$http" in
        200|204|404) ok "deleted runner $label  id=$rid  http=$http" ;;
        *)           warn "runner delete failed: $label  id=$rid  http=$http" ;;
      esac
    done <<< "$_unique"
  fi
else
  warn "no DAYTONA_API_KEY in env - skipping Daytona Cloud runner cleanup"
fi

# ---- 2. delete region from Daytona Cloud ----
# Brief pause for eventual consistency — Daytona Cloud may need a moment to
# reflect the runner deletions before it'll let us delete the region.
if [[ -n "$DAYTONA_API_KEY" && -n "$REGION_ID" ]]; then
  sleep 3
  log "deleting region $REGION_ID from Daytona Cloud"
  resp_body="$(mktemp)"
  http="$(curl -sS --max-time 30 -o "$resp_body" -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions/$REGION_ID" || echo 000)"
  if [[ "$http" =~ ^(200|204|404)$ ]]; then
    ok "region delete returned HTTP $http"
  else
    warn "region delete returned HTTP $http - response body:"
    head -c 400 "$resp_body" | sed 's/^/    /' >&2; echo >&2
    warn "delete the region manually at https://app.daytona.io/dashboard/regions"
  fi
  rm -f "$resp_body"
fi

# ---- 3. helm uninstall (best-effort) ----
if command -v helm >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    log "helm uninstall $RELEASE -n $NAMESPACE"
    helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || warn "helm uninstall failed (continuing)"
    helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || true
    helm uninstall cert-manager -n cert-manager >/dev/null 2>&1 || true
    ok "helm releases uninstalled"
  fi
fi

# ---- 4. terminate EC2 instances ----
if [[ ${#RUNNER_INSTANCE_IDS[@]} -gt 0 ]]; then
  log "terminating EC2 runner instances"
  aws ec2 terminate-instances --instance-ids "${RUNNER_INSTANCE_IDS[@]}" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "${RUNNER_INSTANCE_IDS[@]}" || warn "wait failed"
  ok "instances terminated"
elif [[ -n "$REGION_NAME" ]]; then
  # Tag-based fallback in case .state was lost
  iids="$(aws ec2 describe-instances \
    --filters "Name=tag:daytona:region,Values=$REGION_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$iids" ]]; then
    log "terminating EC2 instances by tag (fallback)"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $iids >/dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $iids || true
    ok "instances terminated"
  fi
fi

# ---- 5. security group + instance profile/role ----
if [[ -n "${RUNNER_SG:-}" ]] || ([[ -n "${SECURITY_GROUP_NAME:-}" ]] && [[ -n "${REGION_NAME:-}" ]]); then
  log "deleting runner security group"
  if [[ -z "${RUNNER_SG:-}" ]]; then
    # Look up by name
    RUNNER_SG="$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  fi
  if [[ -n "${RUNNER_SG:-}" && "${RUNNER_SG}" != "None" ]]; then
    # SG can take a few seconds to be releasable after instance termination
    for attempt in {1..12}; do
      if aws ec2 delete-security-group --group-id "$RUNNER_SG" 2>/dev/null; then
        ok "security group $RUNNER_SG deleted"; break
      fi
      sleep 5
    done || warn "could not delete SG $RUNNER_SG - try again later"
  fi
fi

if [[ -n "${RUNNER_IAM_ROLE_NAME:-}" ]]; then
  log "deleting runner IAM role + instance profile"
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$RUNNER_INSTANCE_PROFILE" \
    --role-name "$RUNNER_IAM_ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$RUNNER_INSTANCE_PROFILE" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$RUNNER_IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$RUNNER_IAM_ROLE_NAME" 2>/dev/null \
    && ok "IAM role + instance profile deleted" || warn "IAM role delete failed (may not exist)"
fi

# ---- 6. eksctl delete cluster ----
if [[ -n "${CLUSTER_NAME:-}" ]] && command -v eksctl >/dev/null 2>&1; then
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "deleting EKS cluster $CLUSTER_NAME (~10-15 min)"
    eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait || warn "eksctl delete returned an error"
    ok "EKS cluster delete completed"
  else
    ok "EKS cluster $CLUSTER_NAME already gone"
  fi
fi

# ---- 7. empty + delete S3 bucket ----
if [[ -n "${S3_BUCKET:-}" ]]; then
  if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
    log "emptying + deleting S3 bucket $S3_BUCKET"
    aws s3 rm "s3://$S3_BUCKET" --recursive >/dev/null 2>&1 || true
    # Versions/delete-markers
    versions_json="$(aws s3api list-object-versions --bucket "$S3_BUCKET" --output json 2>/dev/null || echo '{}')"
    if [[ "$(echo "$versions_json" | jq '(.Versions // []) + (.DeleteMarkers // []) | length')" -gt 0 ]]; then
      echo "$versions_json" | jq '{Objects: [.Versions[]?, .DeleteMarkers[]? | {Key:.Key,VersionId:.VersionId}]}' > "$STATE_DIR/s3-delete.json"
      aws s3api delete-objects --bucket "$S3_BUCKET" --delete "file://$STATE_DIR/s3-delete.json" >/dev/null 2>&1 || true
    fi
    aws s3api delete-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 \
      && ok "bucket deleted" || warn "bucket delete failed (may have objects/versions left)"
  else
    ok "bucket $S3_BUCKET already gone"
  fi
fi

# ---- 8. delete IAM user (keys + policies first) ----
if [[ -n "${IAM_USER_NAME:-}" ]] && aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
  log "deleting IAM user $IAM_USER_NAME"
  for k in $(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$k" 2>/dev/null || true
  done
  for p in $(aws iam list-user-policies --user-name "$IAM_USER_NAME" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-user-policy --user-name "$IAM_USER_NAME" --policy-name "$p" 2>/dev/null || true
  done
  aws iam delete-user --user-name "$IAM_USER_NAME" 2>/dev/null \
    && ok "IAM user deleted" || warn "IAM user delete failed"
fi

# ---- 8b. ECR (private-registry verification) cleanup ----
# Only runs if ecr-setup.sh produced .state/ecr.env.
if [[ -n "${DAYTONA_REGISTRY_ID:-}" && -n "${DAYTONA_REGISTRY_ENDPOINT:-}" && -n "$DAYTONA_API_KEY" ]]; then
  log "deleting Daytona ECR registry registration $DAYTONA_REGISTRY_ID"
  http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/$DAYTONA_REGISTRY_ENDPOINT/$DAYTONA_REGISTRY_ID" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404) ok "  Daytona registry delete returned HTTP $http" ;;
    *)           warn "  Daytona registry delete returned HTTP $http — may need manual cleanup at app.daytona.io/dashboard/registries" ;;
  esac
fi

if [[ -n "${ECR_PULLER_ROLE_NAME:-}" ]] && aws iam get-role --role-name "$ECR_PULLER_ROLE_NAME" >/dev/null 2>&1; then
  log "deleting ECR puller IAM role $ECR_PULLER_ROLE_NAME"
  for p in $(aws iam list-role-policies --role-name "$ECR_PULLER_ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ECR_PULLER_ROLE_NAME" --policy-name "$p" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ECR_PULLER_ROLE_NAME" 2>/dev/null \
    && ok "  ECR puller role deleted" || warn "  ECR puller role delete failed"
fi

# Delete the cached ECR repos (auto-created on first pull through the cache)
# and the pull-through cache rule itself. ECR rejects repo delete if it
# contains images, so use --force.
if [[ -n "${ECR_CACHE_PREFIX:-}" ]]; then
  log "cleaning up ECR pull-through cache for prefix '$ECR_CACHE_PREFIX'"
  # Cached repos look like <prefix>/<upstream-path>
  for repo in $(aws ecr describe-repositories --region "$AWS_REGION" \
                  --query "repositories[?starts_with(repositoryName, '${ECR_CACHE_PREFIX}/')].repositoryName" \
                  --output text 2>/dev/null); do
    [[ -z "$repo" || "$repo" == "None" ]] && continue
    aws ecr delete-repository --repository-name "$repo" --region "$AWS_REGION" --force >/dev/null 2>&1 \
      && ok "  ECR repo deleted: $repo" || warn "  ECR repo delete failed: $repo"
  done
  aws ecr delete-pull-through-cache-rule \
    --ecr-repository-prefix "$ECR_CACHE_PREFIX" \
    --region "$AWS_REGION" >/dev/null 2>&1 \
    && ok "  pull-through cache rule '$ECR_CACHE_PREFIX' deleted" \
    || warn "  pull-through cache rule delete failed (may already be gone)"
fi

# ---- 9. Cloudflare CNAMEs ----
if [[ -n "$DOMAIN" && -n "$CLOUDFLARE_API_TOKEN" ]]; then
  log "removing Cloudflare records for $DOMAIN"
  CF_API="https://api.cloudflare.com/client/v4"
  CF_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")
  candidate="$DOMAIN"; zone_id=""
  while [[ "$candidate" == *.* ]]; do
    id="$(curl -sS --max-time 30 "${CF_AUTH[@]}" "$CF_API/zones?name=$candidate" | jq -r '.result[0].id // empty')"
    [[ -n "$id" ]] && { zone_id="$id"; break; }
    candidate="${candidate#*.}"
  done
  if [[ -n "$zone_id" ]]; then
    for fqdn in "proxy.$DOMAIN" "*.proxy.$DOMAIN" "snapshots.$DOMAIN"; do
      existing="$(curl -sS --max-time 30 "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records?name=$fqdn" | jq -r '.result[].id')"
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        curl -sS --max-time 30 -X DELETE "${CF_AUTH[@]}" "$CF_API/zones/$zone_id/dns_records/$id" >/dev/null && ok "deleted $fqdn" || true
      done <<< "$existing"
    done
  else
    warn "could not find Cloudflare zone for $DOMAIN - skipping DNS cleanup"
  fi
else
  warn "DOMAIN or CLOUDFLARE_API_TOKEN missing - skipping Cloudflare cleanup"
fi

# ---- 10. local state + kubeconfig context ----
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  ok "removed local state $STATE_DIR"
fi
if command -v kubectl >/dev/null 2>&1 && [[ -n "${CLUSTER_NAME:-}" ]]; then
  kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
  kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true
fi

echo
echo "  Teardown complete. Verify with:"
[[ -n "${CLUSTER_NAME:-}" ]] && echo "    aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION   # expect ResourceNotFoundException"
[[ -n "${S3_BUCKET:-}"     ]] && echo "    aws s3api head-bucket --bucket $S3_BUCKET                             # expect 404"
