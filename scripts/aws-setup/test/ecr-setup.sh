#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC setup (AWS) — ECR private-registry verification setup
# =============================================================================
#
# Sets up everything needed to verify the private-registry (ECR) path:
#   a snapshot created from a private AWS ECR image requires the runner's
#   registry inspect job to authenticate to ECR via the broker flow.
#
# We provision:
#   1. An ECR pull-through cache rule for public.ecr.aws (lets us reference a
#      known-good public image under a private ECR URL without docker push)
#   2. An IAM role with the exact trust + permissions policies that Daytona's
#      ECR docs prescribe (trusts the Daytona broker, ExternalId = org ID,
#      grants ECR pull + auth permissions).
#   3. A registered docker-registry entry in Daytona Cloud pointing at this
#      ECR + role ARN, so Daytona's INSPECT_SNAPSHOT_IN_REGISTRY job uses
#      the broker → AssumeRole → ECR-token flow on every pull.
#
# After running this, e2e.sh Stage C drives the SDK to create a sandbox from
# the cached ECR image. Sandbox start = end-to-end proof the broker flow
# works when configured correctly.
#
# Usage:
#   bash ecr-setup.sh                # idempotent; safe to re-run
#
# Required env:
#   DAYTONA_API_KEY    personal Daytona API key (dtn_...)
#   REGION_NAME        the BYOC region this ECR test is associated with;
#                      auto-read from .state/names.env if present
#
# STRONGLY RECOMMENDED (skip auto-discovery, which is best-effort):
#   DAYTONA_ORG_ID     your org ID. Find it in your dashboard URL after login:
#                        https://app.daytona.io/dashboard/<ORG_ID>/sandboxes
#                      The script will try to auto-discover from a handful of
#                      candidate API endpoints, but Daytona's API doesn't
#                      publicly expose this and shape varies between releases.
#                      Set this env var upfront and skip the guesswork.
#
# Optional env:
#   DAYTONA_API_URL    default https://app.daytona.io/api
#   AWS_DEFAULT_REGION default us-east-1
#   DAYTONA_BROKER_ARN default arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker
#                      (Daytona Cloud SaaS broker; substitute your API IRSA
#                       role ARN if running full self-hosted)
# =============================================================================

set -euo pipefail
export AWS_PAGER=""

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*" ; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*" ; }
die()  { printf '\033[1;31m  err\033[0m  %s\n' "$*" >&2 ; exit 1 ; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"

# Pick up region name from prior repro state if it isn't passed in
[[ -z "${REGION_NAME:-}" && -f "$STATE_DIR/names.env" ]] && source "$STATE_DIR/names.env"

DAYTONA_API_KEY="${DAYTONA_API_KEY:?Set DAYTONA_API_KEY (personal key from app.daytona.io/dashboard/keys)}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
AWS_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
REGION_NAME="${REGION_NAME:?Set REGION_NAME (or run after repro.sh which writes .state/names.env)}"
DAYTONA_BROKER_ARN="${DAYTONA_BROKER_ARN:-arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker}"

# Derived
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_CACHE_PREFIX="ecr-public"
ECR_TEST_IMAGE="${ECR_REGISTRY_URL}/${ECR_CACHE_PREFIX}/docker/library/alpine:3.21"
ECR_PULLER_ROLE_NAME="$(printf '%s' "${REGION_NAME}-ecr-puller" | cut -c1-64)"

log "ECR private-registry setup"
ok "  AWS account:   $AWS_ACCOUNT_ID"
ok "  ECR registry:  $ECR_REGISTRY_URL"
ok "  test image:    $ECR_TEST_IMAGE"
ok "  puller role:   $ECR_PULLER_ROLE_NAME"
ok "  Daytona broker: $DAYTONA_BROKER_ARN"

# --------------------------------------------------------------------------
# 1. ECR pull-through cache rule.
#    Lets us reference `public.ecr.aws/docker/library/alpine` as a private
#    ECR image under our account — without ever needing local docker. ECR
#    materialises the cache repo on first pull.
# --------------------------------------------------------------------------
log "  pull-through cache rule for $ECR_CACHE_PREFIX → public.ecr.aws"
if aws ecr describe-pull-through-cache-rules \
     --ecr-repository-prefix "$ECR_CACHE_PREFIX" \
     --region "$AWS_REGION" >/dev/null 2>&1; then
  ok "    already exists"
else
  aws ecr create-pull-through-cache-rule \
    --ecr-repository-prefix "$ECR_CACHE_PREFIX" \
    --upstream-registry-url public.ecr.aws \
    --region "$AWS_REGION" >/dev/null
  ok "    created"
fi

# --------------------------------------------------------------------------
# 2. Discover Daytona organization ID.
#    Used as ExternalId in the IAM trust policy.
#
# We isolate the discovery in a function with `set +e` because `curl | jq`
# with `set -euo pipefail` will kill the script if any endpoint returns
# something jq can't parse (HTML 404 page → jq exit 5 → set -e kills us).
# The function returns empty on any failure; the caller decides what to do.
# --------------------------------------------------------------------------
discover_org_id() {
  set +e
  local path query candidate found=""
  local endpoints=(
    "users/me|.organizationId"
    "users/me|.organization.id"
    "users/me|.defaultOrganizationId"
    "users/me|.orgId"
    "organizations|.[0].id"
    "organizations|.items[0].id"
    "organizations|.data[0].id"
    "orgs|.[0].id"
  )
  for path_query in "${endpoints[@]}"; do
    IFS='|' read -r path query <<< "$path_query"
    candidate=$(curl -sS --max-time 10 \
      -H "Authorization: Bearer $DAYTONA_API_KEY" \
      "$DAYTONA_API_URL/$path" 2>/dev/null \
      | jq -r "$query // empty" 2>/dev/null)
    if [[ -n "$candidate" && "$candidate" != "null" ]]; then
      found="$candidate"
      printf '%s|%s|%s\n' "$found" "$path" "$query"
      break
    fi
  done
  set -e
  return 0
}

log "  discovering Daytona organization ID"
DAYTONA_ORG_ID="${DAYTONA_ORG_ID:-}"
if [[ -z "$DAYTONA_ORG_ID" ]]; then
  result="$(discover_org_id)"
  if [[ -n "$result" ]]; then
    IFS='|' read -r DAYTONA_ORG_ID hit_path hit_query <<< "$result"
    ok "    discovered via /$hit_path → $hit_query"
  fi
fi
if [[ -z "$DAYTONA_ORG_ID" ]]; then
  warn "    auto-discovery failed — the Daytona API doesn't expose org ID at any"
  warn "    endpoint we tried (users/me, organizations, orgs)."
  warn ""
  warn "    HOW TO GET YOUR ORG ID:"
  warn "      1. Open https://app.daytona.io in your browser"
  warn "      2. Look at the URL after login. It looks like:"
  warn "           https://app.daytona.io/dashboard/<ORG_ID>/sandboxes"
  warn "         The <ORG_ID> path segment is what you need."
  warn "      3. Re-run with it set:"
  warn "           DAYTONA_ORG_ID=<paste-it-here> bash ecr-setup.sh"
  warn ""
  warn "    (You can verify it's right: it's also shown on your org settings page,"
  warn "    and on the ECR registry form in /dashboard/registries.)"
  die  "    DAYTONA_ORG_ID required for IAM trust policy ExternalId."
fi
ok "  organization ID: $DAYTONA_ORG_ID"

# --------------------------------------------------------------------------
# 3. IAM role with trust + permissions policies.
#    Permissions are a superset of what the Daytona docs prescribe — extras
#    (CreateRepository, BatchImportUpstreamImage) are required for ECR
#    pull-through cache to materialise repos on demand.
# --------------------------------------------------------------------------
log "  IAM role $ECR_PULLER_ROLE_NAME"
TRUST_POLICY="$(jq -n --arg arn "$DAYTONA_BROKER_ARN" --arg ext "$DAYTONA_ORG_ID" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { AWS: $arn },
    Action: "sts:AssumeRole",
    Condition: { StringEquals: { "sts:ExternalId": $ext } }
  }]
}')"
PERMS_POLICY="$(jq -n '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Action: [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage"
    ],
    Resource: "*"
  }]
}')"

if aws iam get-role --role-name "$ECR_PULLER_ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ECR_PULLER_ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
  ok "    role exists; trust policy updated"
else
  aws iam create-role --role-name "$ECR_PULLER_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Daytona BYOC ECR puller (aws-repro ecr-setup.sh)" >/dev/null
  ok "    role created"
fi

aws iam put-role-policy --role-name "$ECR_PULLER_ROLE_NAME" \
  --policy-name "${ECR_PULLER_ROLE_NAME}-ecr-perms" \
  --policy-document "$PERMS_POLICY" >/dev/null

ECR_PULLER_ROLE_ARN="$(aws iam get-role --role-name "$ECR_PULLER_ROLE_NAME" --query 'Role.Arn' --output text)"
ok "    role ARN: $ECR_PULLER_ROLE_ARN"

# Give IAM a moment to propagate
sleep 5

# --------------------------------------------------------------------------
# 4. Register the ECR registry in Daytona Cloud.
#    The exact endpoint/field shape isn't publicly documented, so we try
#    several variants. If all fail, we fall back to clear manual instructions.
# --------------------------------------------------------------------------
log "  registering ECR with Daytona"

REGISTRY_NAME="${REGION_NAME}-ecr"
DAYTONA_REGISTRY_ID=""
DAYTONA_REGISTRY_ENDPOINT=""

# If we already registered before (state survived from a prior run), short-circuit
if [[ -f "$STATE_DIR/ecr.env" ]]; then
  source "$STATE_DIR/ecr.env"
  if [[ -n "${DAYTONA_REGISTRY_ID:-}" && -n "${DAYTONA_REGISTRY_ENDPOINT:-}" ]]; then
    # Verify it's still there
    check_http="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $DAYTONA_API_KEY" \
      "$DAYTONA_API_URL/$DAYTONA_REGISTRY_ENDPOINT/$DAYTONA_REGISTRY_ID" 2>/dev/null || echo 000)"
    if [[ "$check_http" == "200" ]]; then
      ok "    already registered: $DAYTONA_REGISTRY_ID (via /$DAYTONA_REGISTRY_ENDPOINT)"
    else
      DAYTONA_REGISTRY_ID=""  # was deleted out-of-band; re-register
    fi
  fi
fi

if [[ -z "$DAYTONA_REGISTRY_ID" ]]; then
  # Common payload variants (different Daytona versions use different field names)
  declare -a PAYLOAD_VARIANTS=(
    "$(jq -n --arg n "$REGISTRY_NAME" --arg u "$ECR_REGISTRY_URL" \
            --arg p "$ECR_CACHE_PREFIX" --arg acct "$AWS_ACCOUNT_ID" \
            --arg reg "$AWS_REGION" --arg role "$ECR_PULLER_ROLE_ARN" \
        '{name:$n, url:$u, project:$p, registryType:"AWS_ECR",
          awsAccountId:$acct, awsRegion:$reg, awsRoleArn:$role}')"
    "$(jq -n --arg n "$REGISTRY_NAME" --arg u "$ECR_REGISTRY_URL" \
            --arg role "$ECR_PULLER_ROLE_ARN" \
        '{name:$n, url:$u, type:"ecr", roleArn:$role}')"
    "$(jq -n --arg n "$REGISTRY_NAME" --arg u "$ECR_REGISTRY_URL" \
            --arg role "$ECR_PULLER_ROLE_ARN" \
        '{name:$n, url:$u, provider:"ecr", awsRoleArn:$role}')"
  )

  for endpoint in docker-registries registries dockerRegistries private-registries; do
    for payload in "${PAYLOAD_VARIANTS[@]}"; do
      body=$(mktemp)
      http=$(curl -sS -o "$body" -w '%{http_code}' \
        -X POST "$DAYTONA_API_URL/$endpoint" \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        -H "X-Daytona-Organization-ID: $DAYTONA_ORG_ID" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo 000)
      if [[ "$http" =~ ^(200|201)$ ]]; then
        DAYTONA_REGISTRY_ID="$(jq -r '.id // empty' < "$body")"
        DAYTONA_REGISTRY_ENDPOINT="$endpoint"
        rm -f "$body"
        ok "    registered: $DAYTONA_REGISTRY_ID  (POST /$endpoint)"
        break 2
      fi
      rm -f "$body"
    done
  done
fi

if [[ -z "$DAYTONA_REGISTRY_ID" ]]; then
  warn "    automated registration failed against every endpoint tried."
  warn "    Manual fallback:"
  warn "      1. https://app.daytona.io/dashboard/registries"
  warn "      2. Add Registry → Amazon ECR tab"
  warn "      3. Registry URL: $ECR_REGISTRY_URL"
  warn "      4. Role ARN:    $ECR_PULLER_ROLE_ARN"
  warn "    Then re-run e2e.sh — Stage C will pick up the registry by URL."
fi

# --------------------------------------------------------------------------
# Write state for e2e.sh + teardown.sh to consume
# --------------------------------------------------------------------------
cat > "$STATE_DIR/ecr.env" <<EOF
ECR_REGISTRY_URL="$ECR_REGISTRY_URL"
ECR_TEST_IMAGE="$ECR_TEST_IMAGE"
ECR_PULLER_ROLE_NAME="$ECR_PULLER_ROLE_NAME"
ECR_PULLER_ROLE_ARN="$ECR_PULLER_ROLE_ARN"
ECR_CACHE_PREFIX="$ECR_CACHE_PREFIX"
DAYTONA_REGISTRY_ID="${DAYTONA_REGISTRY_ID:-}"
DAYTONA_REGISTRY_ENDPOINT="${DAYTONA_REGISTRY_ENDPOINT:-}"
DAYTONA_ORG_ID="$DAYTONA_ORG_ID"
DAYTONA_BROKER_ARN="$DAYTONA_BROKER_ARN"
EOF
ok "state written to $STATE_DIR/ecr.env"
log "done. Now run e2e.sh — Stage C will exercise the ECR pull."
