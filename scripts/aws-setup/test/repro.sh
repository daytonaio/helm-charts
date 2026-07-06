#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC on AWS — end-to-end deployment
# =============================================================================
#
# Walks through the FULL deployment of Daytona BYOC on AWS:
#
#   Phase 1-4: preflight (tools, AWS auth, Daytona key, Cloudflare token)
#   Phase 5-6: AWS S3 bucket + IAM user (used by snapshot-manager AND runners)
#   Phase 7-8: EKS cluster (eksctl creates VPC + node group)
#   Phase 9-11: ingress-nginx + Cloudflare DNS + cert-manager
#   Phase 12: daytona-region helm chart (registers a custom region with
#             Daytona Cloud and brings up proxy + snapshot manager)
#   Phase 13-14: EC2 runner instances + SSM bootstrap (registers each as a
#                Daytona runner under our region; configures the declarative
#                builder S3 env vars to point at the same bucket)
#   Phase 15: SDK validation — create a sandbox targeting the new region
#
# You keep using Daytona Cloud (app.daytona.io) as the CONTROL PLANE.
# Your EKS cluster hosts the region INFRASTRUCTURE (proxy + snapshot manager).
# Your EC2 instances are the COMPUTE (run the sandboxes themselves).
#
# Required env vars:
#   DAYTONA_API_KEY      - personal API key from app.daytona.io/dashboard/keys
#   DOMAIN               - FQDN you own, e.g. byoc.yourdomain.com. Used for
#                          proxy.${DOMAIN} and snapshots.${DOMAIN}.
#   ACME_EMAIL           - email for Let's Encrypt registration
#   CLOUDFLARE_API_TOKEN - Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)
#                          for the parent zone of ${DOMAIN}
#
# AWS auth - any one of:
#   - AWS_PROFILE set to a configured profile
#   - AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in env
#   - IAM Identity Center / sso login active
#   Script verifies via `aws sts get-caller-identity` before doing anything.
#
# Optional (with defaults):
#   DAYTONA_API_URL          https://app.daytona.io/api
#   AWS_DEFAULT_REGION       us-east-1
#   CLUSTER_NAME             daytona-byoc-aws (suffixed with stable hash)
#   K8S_VERSION              1.30
#   NODE_INSTANCE_TYPE       m7i.large       (for EKS control-plane pods)
#   NODE_COUNT               2               (EKS node count for control)
#   RUNNER_COUNT             4               (m7i.2xlarge each — matches the prod-shape
#                                              16 sandboxes × 4 vCPU × 2x over-prov sizing)
#   RUNNER_INSTANCE_TYPE     m7i.2xlarge
#   RUNNER_VOLUME_GB         100
#   REGION_NAME              eks-byoc-<timestamp>   (auto)
#   RUNNER_NAME_PREFIX       eks-runner            (each instance gets a numeric suffix)
#   STAGING                  false                 (LE staging vs prod CA)
#   PHASE                    5                     (1..5 — stop after this phase)
#   SKIP_E2E                 false
#
# Re-runs are largely idempotent. teardown.sh nukes everything.
# =============================================================================

set -euo pipefail

# AWS CLI v2 pipes any non-trivial output through `less` by default. That
# stops the script dead waiting for `q`, hides errors from the scrollback,
# and is just generally awful for automation. Turn it off everywhere.
export AWS_PAGER=""

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
AWS_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# Stable cluster name suffix derived from $DOMAIN so re-runs hit the same
# cluster. Keeps the cluster name <40 chars (eksctl/CloudFormation limit).
_hash="$(printf '%s' "$DOMAIN" | shasum | cut -c1-6)"
CLUSTER_NAME="${CLUSTER_NAME:-daytona-byoc-aws-$_hash}"
K8S_VERSION="${K8S_VERSION:-1.30}"
NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-m7i.large}"
NODE_COUNT="${NODE_COUNT:-2}"
RUNNER_COUNT="${RUNNER_COUNT:-4}"
RUNNER_INSTANCE_TYPE="${RUNNER_INSTANCE_TYPE:-m7i.2xlarge}"
RUNNER_VOLUME_GB="${RUNNER_VOLUME_GB:-100}"

NAMESPACE="${NAMESPACE:-daytona-region}"
RELEASE="${RELEASE:-daytona-region}"
CHART_PATH="${CHART_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/charts/daytona-region}"
STAGING="${STAGING:-false}"
SKIP_E2E="${SKIP_E2E:-false}"
PHASE="${PHASE:-5}"

# Auto-generated names with timestamp suffix - written to state for idempotency
STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"
if [[ -f "$STATE_DIR/names.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/names.env"
else
  REGION_NAME="${REGION_NAME:-eks-byoc-$(date +%s)}"
  RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-eks-runner}"
  printf 'REGION_NAME=%q\nRUNNER_NAME_PREFIX=%q\n' \
    "$REGION_NAME" "$RUNNER_NAME_PREFIX" > "$STATE_DIR/names.env"
fi

# S3 + IAM resource names. The bucket and IAM user names are deterministic
# from $REGION_NAME so re-runs land on the same resources.
S3_BUCKET="${S3_BUCKET:-${REGION_NAME}-snapshots}"
# Trim to S3's 63-char limit + lowercase
S3_BUCKET="$(printf '%s' "$S3_BUCKET" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"
IAM_USER_NAME="${IAM_USER_NAME:-${REGION_NAME}-s3}"
IAM_USER_NAME="$(printf '%s' "$IAM_USER_NAME" | cut -c1-64)"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-${REGION_NAME}-runner-sg}"
RUNNER_IAM_ROLE_NAME="${RUNNER_IAM_ROLE_NAME:-${REGION_NAME}-runner-role}"
RUNNER_IAM_ROLE_NAME="$(printf '%s' "$RUNNER_IAM_ROLE_NAME" | cut -c1-64)"
RUNNER_INSTANCE_PROFILE="$RUNNER_IAM_ROLE_NAME"

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
for t in aws eksctl kubectl helm jq curl openssl envsubst shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
[[ -d "$CHART_PATH" ]] || die "daytona-region chart not found at $CHART_PATH"
ok "tools present; chart at $CHART_PATH"
ok "region: $REGION_NAME    runner prefix: $RUNNER_NAME_PREFIX (×$RUNNER_COUNT)"
ok "cluster: $CLUSTER_NAME    aws region: $AWS_REGION"

# ---------- 2. aws auth ----------
log "phase 2/15 - aws auth"
caller="$(aws sts get-caller-identity --output json 2>/dev/null || true)"
[[ -z "$caller" ]] && die "aws CLI cannot authenticate. Set AWS_PROFILE or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, or run 'aws configure'/'aws sso login'."
AWS_ACCOUNT_ID="$(echo "$caller" | jq -r '.Account')"
AWS_CALLER_ARN="$(echo "$caller" | jq -r '.Arn')"
ok "account: $AWS_ACCOUNT_ID  identity: $AWS_CALLER_ARN"

# ---------- 3. daytona api key sanity check (fail fast) ----------
log "phase 3/15 - daytona api key sanity"
# Hit /regions — this is the authenticated endpoint Daytona's own docs use
# as the canonical example. Available to any org member with an API key.
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
    Things to check:
      1. The key was copied without leading/trailing whitespace.
      2. The key starts with 'dtn_'.
      3. The key was generated at app.daytona.io/dashboard/keys (not somewhere else).
      4. \$DAYTONA_API_URL is what you expect: $DAYTONA_API_URL
      5. Try manually:
           curl -sS -H \"Authorization: Bearer \$DAYTONA_API_KEY\" $DAYTONA_API_URL/regions"
    ;;
  000)
    rm -f "$_resp_body"
    die "could not reach $DAYTONA_API_URL (curl failed — DNS/network issue?)"
    ;;
  *)
    warn "unexpected HTTP $_http from $DAYTONA_API_URL/regions — response body:"
    head -c 500 "$_resp_body" | sed 's/^/    /'; echo
    rm -f "$_resp_body"
    warn "continuing anyway (the key may still work for the actual API calls)"
    ;;
esac

# ---------- 4. cloudflare zone + token verify ----------
log "phase 4/15 - cloudflare DNS lookup + token verify"
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

(( PHASE >= 1 )) || { log "PHASE=$PHASE - stopping after preflight"; exit 0; }

# ---------- 5. S3 bucket ----------
log "phase 5/15 - S3 bucket $S3_BUCKET ($AWS_REGION)"
if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  ok "bucket $S3_BUCKET already exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  # Block public access and enable default encryption
  aws s3api put-public-access-block --bucket "$S3_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  aws s3api put-bucket-encryption --bucket "$S3_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  ok "bucket created + locked down"
fi

# ---------- 6. IAM user for snapshot-manager + runners ----------
log "phase 6/15 - IAM user $IAM_USER_NAME + access keys + S3 policy"
S3_POLICY_DOC="$(jq -n --arg b "$S3_BUCKET" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Action: [
      "s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket",
      "s3:AbortMultipartUpload","s3:ListMultipartUploadParts","s3:GetBucketLocation"
    ],
    Resource: ["arn:aws:s3:::\($b)","arn:aws:s3:::\($b)/*"]
  }]
}')"

if ! aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
  aws iam create-user --user-name "$IAM_USER_NAME" >/dev/null
  ok "IAM user created"
else
  ok "IAM user already exists"
fi

aws iam put-user-policy --user-name "$IAM_USER_NAME" \
  --policy-name "${IAM_USER_NAME}-s3" \
  --policy-document "$S3_POLICY_DOC" >/dev/null
ok "inline S3 policy attached"

# Use stored keys if present; otherwise rotate.
if [[ -f "$STATE_DIR/iam-keys.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/iam-keys.env"
  ok "reusing IAM access key $IAM_ACCESS_KEY"
else
  # Clean up any pre-existing keys we don't know the secret for
  for k in $(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$k" >/dev/null || true
  done
  key_json="$(aws iam create-access-key --user-name "$IAM_USER_NAME" --output json)"
  IAM_ACCESS_KEY="$(echo "$key_json" | jq -r '.AccessKey.AccessKeyId')"
  IAM_SECRET_KEY="$(echo "$key_json" | jq -r '.AccessKey.SecretAccessKey')"
  printf 'IAM_ACCESS_KEY=%q\nIAM_SECRET_KEY=%q\n' \
    "$IAM_ACCESS_KEY" "$IAM_SECRET_KEY" > "$STATE_DIR/iam-keys.env"
  chmod 600 "$STATE_DIR/iam-keys.env"
  ok "new IAM access key created: $IAM_ACCESS_KEY"
fi

# Quick sanity check: can these keys list the bucket?
log "  verifying IAM keys can access the bucket"
attempt=0
until AWS_ACCESS_KEY_ID="$IAM_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$IAM_SECRET_KEY" \
      aws s3 ls "s3://$S3_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if (( attempt > 20 )); then die "IAM keys can't reach s3://$S3_BUCKET after 20 attempts (~60s)"; fi
  printf '\r    waiting for IAM propagation... %ds' $((attempt * 3)); sleep 3
done
echo
ok "IAM keys verified against s3://$S3_BUCKET"

# ---------- 7. EKS cluster ----------
log "phase 7/15 - EKS cluster $CLUSTER_NAME (~15 min on first run)"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  ok "EKS cluster $CLUSTER_NAME already exists"
else
  cat > "$STATE_DIR/eksctl-cluster.yaml" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $AWS_REGION
  version: "$K8S_VERSION"
managedNodeGroups:
  - name: control
    instanceType: $NODE_INSTANCE_TYPE
    desiredCapacity: $NODE_COUNT
    minSize: $NODE_COUNT
    maxSize: $NODE_COUNT
    volumeSize: 50
    volumeType: gp3
    iam:
      withAddonPolicies:
        ebs: true
        externalDNS: false
        certManager: false
        cloudWatch: false
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
EOF
  eksctl create cluster -f "$STATE_DIR/eksctl-cluster.yaml"
  ok "EKS cluster created"
fi

# ---------- 8. kubeconfig + VPC discovery ----------
log "phase 8/15 - kubeconfig + VPC discovery"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME" >/dev/null
kubectl cluster-info >/dev/null || die "kubectl cannot reach cluster"
ok "kubeconfig set; context: $(kubectl config current-context)"

EKS_VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
EKS_CLUSTER_SG="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
# Pick a public subnet for the runner instances (eksctl tags public subnets with kubernetes.io/role/elb=1)
EKS_PUBLIC_SUBNETS="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$EKS_VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text)"
[[ -z "$EKS_PUBLIC_SUBNETS" ]] && die "no public subnets found in VPC $EKS_VPC_ID (kubernetes.io/role/elb tag missing)"
RUNNER_SUBNET="$(echo "$EKS_PUBLIC_SUBNETS" | awk '{print $1}')"
ok "VPC $EKS_VPC_ID, runner subnet $RUNNER_SUBNET, cluster SG $EKS_CLUSTER_SG"

# ---------- 9. ingress-nginx + wait for LB hostname + CNAMEs ----------
log "phase 9/15 - ingress-nginx (NLB) + Cloudflare CNAMEs"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb" \
  --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing" \
  --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled=true" \
  --wait --timeout 5m >/dev/null
ok "ingress-nginx installed"

LB_HOSTNAME=""
for i in {1..60}; do
  LB_HOSTNAME="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$LB_HOSTNAME" ]] && break
  printf '\r    waiting for NLB hostname... %ds' $((i*5)); sleep 5
done
echo
[[ -n "$LB_HOSTNAME" ]] || die "no NLB hostname after 5 min"
ok "NLB hostname: $LB_HOSTNAME"

log "  writing Cloudflare CNAME records for $DOMAIN -> $LB_HOSTNAME"
cf_upsert_cname() {
  local fqdn="$1" target="$2"
  local existing
  existing="$(curl -sS "${CF_AUTH[@]}" "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$fqdn" | jq -r '.result[].id')"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    curl -sS -X DELETE "${CF_AUTH[@]}" "$CF_API/zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
  done <<< "$existing"
  local resp
  resp="$(curl -sS "${CF_AUTH[@]}" -X POST "$CF_API/zones/$CF_ZONE_ID/dns_records" \
    --data "{\"type\":\"CNAME\",\"name\":\"$fqdn\",\"content\":\"$target\",\"ttl\":60,\"proxied\":false}")"
  [[ "$(echo "$resp" | jq -r '.success')" == "true" ]] || die "DNS upsert failed for $fqdn: $resp"
}
cf_upsert_cname "proxy.$DOMAIN" "$LB_HOSTNAME"
cf_upsert_cname "*.proxy.$DOMAIN" "$LB_HOSTNAME"
cf_upsert_cname "snapshots.$DOMAIN" "$LB_HOSTNAME"
ok "DNS CNAME records written for proxy, *.proxy, snapshots"

# ---------- 10. cert-manager + ClusterIssuer ----------
log "phase 10/15 - cert-manager"
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
log "phase 11/15 - daytona-region namespace + Certificates"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Save the certificate manifests to disk so the cert-wait step (phase 14.5)
# can re-apply them verbatim if Let's Encrypt fails to finalize (see that
# step for the rationale).
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

(( PHASE >= 2 )) || { log "PHASE=$PHASE - stopping after region infra setup"; exit 0; }
(( PHASE >= 3 )) || { log "PHASE=$PHASE - stopping before helm install"; exit 0; }

# ---------- 12. helm install daytona-region ----------
log "phase 12/15 - helm install daytona-region"
DOMAIN="$DOMAIN" \
REGION_NAME="$REGION_NAME" \
DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
AWS_REGION="$AWS_REGION" \
S3_BUCKET="$S3_BUCKET" \
IAM_ACCESS_KEY="$IAM_ACCESS_KEY" \
IAM_SECRET_KEY="$IAM_SECRET_KEY" \
  envsubst < "$SCRIPT_DIR/values-region.yaml.tmpl" > "$STATE_DIR/values-region.yaml"

helm upgrade --install "$RELEASE" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$STATE_DIR/values-region.yaml" \
  --timeout 10m >/dev/null
ok "helm install completed - pre-install hook registered region '$REGION_NAME' with Daytona Cloud"

log "  reading region credentials from the secret the registration hook wrote"
SECRET_NAME="$(kubectl -n "$NAMESPACE" get secret -l app.kubernetes.io/component=region-config -o name | head -1)"
[[ -n "$SECRET_NAME" ]] || SECRET_NAME="secret/$RELEASE-region-config"
REGION_ID="$(kubectl -n "$NAMESPACE" get "$SECRET_NAME" -o jsonpath='{.data.id}' | base64 -d 2>/dev/null || true)"
echo "$REGION_ID" > "$STATE_DIR/region-id.txt"
ok "region registered: id=$REGION_ID"

log "  waiting for proxy + snapshot-manager pods to be Ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance="$RELEASE" \
  --timeout=10m || warn "not all pods Ready; inspect with: kubectl -n $NAMESPACE get pods"
ok "region services running"

(( PHASE >= 4 )) || { log "PHASE=$PHASE - stopping after helm install"; exit 0; }

# ---------- 13. runner security group + IAM role + EC2 instances ----------
log "phase 13/15 - $RUNNER_COUNT x $RUNNER_INSTANCE_TYPE runner instances"

# Security group: allow inbound 3000 + 2220 from the EKS cluster SG (so the
# in-cluster proxy can reach the runner) and SSM-required outbound (which is
# permitted by the default egress rule).
RUNNER_SG=""
existing_sg="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$EKS_VPC_ID" "Name=group-name,Values=$SECURITY_GROUP_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -n "$existing_sg" && "$existing_sg" != "None" ]]; then
  RUNNER_SG="$existing_sg"
  ok "security group already exists: $RUNNER_SG"
else
  RUNNER_SG="$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Daytona BYOC runner - in-cluster proxy access (ASCII only per AWS rules)" \
    --vpc-id "$EKS_VPC_ID" \
    --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --group-id "$RUNNER_SG" \
    --protocol tcp --port 3000 --source-group "$EKS_CLUSTER_SG" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$RUNNER_SG" \
    --protocol tcp --port 2220 --source-group "$EKS_CLUSTER_SG" >/dev/null
  ok "security group created: $RUNNER_SG (ingress 3000+2220 from $EKS_CLUSTER_SG)"
fi

# IAM role + instance profile for SSM. The runner uses its own static IAM
# user keys for S3 access (passed in via SSM env), so this role only carries
# AmazonSSMManagedInstanceCore.
if ! aws iam get-role --role-name "$RUNNER_IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$RUNNER_IAM_ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  ok "IAM role created"
else
  ok "IAM role already exists"
fi
aws iam attach-role-policy --role-name "$RUNNER_IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

if ! aws iam get-instance-profile --instance-profile-name "$RUNNER_INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$RUNNER_INSTANCE_PROFILE" >/dev/null
fi
# Attach role to instance profile if not already
aws iam add-role-to-instance-profile \
  --instance-profile-name "$RUNNER_INSTANCE_PROFILE" \
  --role-name "$RUNNER_IAM_ROLE_NAME" 2>/dev/null || true

# Wait for the instance profile to have its role visible AT THE IAM API level.
# This is the fast wait — IAM is eventually consistent but usually completes in
# 1-2 seconds. After this we still need to wait for EC2 to see it, which is the
# slower hop handled by the retry loop in the run-instances call below.
log "  waiting for IAM to show role attached to instance profile"
attempt=0
while true; do
  attached="$(aws iam get-instance-profile \
    --instance-profile-name "$RUNNER_INSTANCE_PROFILE" \
    --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || true)"
  [[ "$attached" == "$RUNNER_IAM_ROLE_NAME" ]] && break
  attempt=$((attempt + 1))
  (( attempt > 30 )) && die "instance profile still has no role after 60s"
  sleep 2
done
ok "instance profile $RUNNER_INSTANCE_PROFILE ready (role attached)"

# Latest Ubuntu 22.04 LTS AMI in this region
UBUNTU_AMI="$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"
ok "Ubuntu 22.04 AMI: $UBUNTU_AMI"

# Helper: run-instances with retry to handle IAM eventual consistency.
# AWS docs explicitly call out that newly-created instance profiles can take
# tens of seconds to become visible to EC2's RunInstances API. We retry on the
# specific error ("Invalid IAM Instance Profile name") with linear backoff
# and surface any other error immediately.
run_instances_with_retry() {
  local rname="$1"
  local max_attempts=24      # ~2 minutes total
  local delay=5
  local attempt=0
  local out err iid
  while true; do
    attempt=$((attempt + 1))
    err="$(mktemp)"
    iid="$(aws ec2 run-instances \
      --image-id "$UBUNTU_AMI" \
      --instance-type "$RUNNER_INSTANCE_TYPE" \
      --subnet-id "$RUNNER_SUBNET" \
      --security-group-ids "$RUNNER_SG" \
      --associate-public-ip-address \
      --iam-instance-profile "Name=$RUNNER_INSTANCE_PROFILE" \
      --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$RUNNER_VOLUME_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$rname},{Key=daytona:region,Value=$REGION_NAME}]" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --query 'Instances[0].InstanceId' --output text 2>"$err")" && {
        rm -f "$err"
        echo "$iid"
        return 0
      }
    out="$(cat "$err")"; rm -f "$err"
    if echo "$out" | grep -qE 'Invalid IAM Instance Profile name|InvalidParameterValue.*iamInstanceProfile'; then
      if (( attempt >= max_attempts )); then
        warn "  $rname: instance profile still not visible to EC2 after ~2 min"
        echo "$out" >&2
        return 1
      fi
      # IMPORTANT: spinner goes to stderr. This function's stdout is captured
      # by `iid="$(run_instances_with_retry ...)"` so anything we echo to
      # stdout becomes part of the captured "instance ID" string and breaks
      # downstream calls (e.g. `aws ec2 wait` rejects malformed IDs).
      printf '\r    %s waiting for EC2 to see the instance profile (attempt %d/%d)...' "$rname" "$attempt" "$max_attempts" >&2
      sleep "$delay"
      continue
    fi
    # Non-retryable error
    warn "  $rname: run-instances failed (non-retryable)"
    echo "$out" >&2
    return 1
  done
}

# Provision RUNNER_COUNT instances, idempotently.
declare -a RUNNER_INSTANCE_IDS=()
declare -a RUNNER_PUBLIC_IPS=()
declare -a RUNNER_NAMES=()
for idx in $(seq 1 "$RUNNER_COUNT"); do
  rname="${RUNNER_NAME_PREFIX}-${idx}"
  existing="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$rname" \
              "Name=tag:daytona:region,Values=$REGION_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    iid="$(echo "$existing" | awk '{print $1}')"
    ok "  $rname already exists: $iid"
  else
    iid="$(run_instances_with_retry "$rname")" || die "could not launch $rname (see error above)"
    echo >&2  # newline after the spinner line (spinner goes to stderr too)
    # Defensive: even though the spinner is now on stderr, make sure the
    # captured iid is exactly a valid instance ID (i- followed by hex). If it
    # isn't, something else leaked into stdout and we should fail loudly here
    # rather than passing a broken string to `aws ec2 wait` downstream.
    if [[ ! "$iid" =~ ^i-[0-9a-f]+$ ]]; then
      warn "  captured instance ID for $rname is not a valid i-* id:"
      printf '  %q\n' "$iid" >&2
      die "run_instances_with_retry returned a malformed value — see above"
    fi
    ok "  $rname launched: $iid"
  fi
  RUNNER_INSTANCE_IDS+=("$iid")
  RUNNER_NAMES+=("$rname")
done

# Wait for all instances to be 'running' AND SSM-managed before bootstrap.
log "  waiting for instances to enter 'running' state"
aws ec2 wait instance-running --instance-ids "${RUNNER_INSTANCE_IDS[@]}"
for i in "${!RUNNER_INSTANCE_IDS[@]}"; do
  pip="$(aws ec2 describe-instances --instance-ids "${RUNNER_INSTANCE_IDS[$i]}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  RUNNER_PUBLIC_IPS+=("$pip")
done

log "  waiting for SSM agent to register (up to 5 min)"
for i in "${!RUNNER_INSTANCE_IDS[@]}"; do
  iid="${RUNNER_INSTANCE_IDS[$i]}"
  attempts=0
  while true; do
    status="$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$iid" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
    [[ "$status" == "Online" ]] && break
    attempts=$((attempts + 1))
    (( attempts > 60 )) && die "instance $iid not SSM-reachable after 5 min"
    printf '\r    %s waiting for SSM... %ds' "${RUNNER_NAMES[$i]}" $((attempts * 5)); sleep 5
  done
  echo
  ok "  ${RUNNER_NAMES[$i]} ($iid, ${RUNNER_PUBLIC_IPS[$i]}) SSM Online"
done

# Save runner state for teardown
{
  echo "RUNNER_INSTANCE_IDS=(${RUNNER_INSTANCE_IDS[*]})"
  echo "RUNNER_NAMES=(${RUNNER_NAMES[*]})"
  echo "RUNNER_PUBLIC_IPS=(${RUNNER_PUBLIC_IPS[*]})"
  echo "RUNNER_SG=$RUNNER_SG"
} > "$STATE_DIR/runners.env"

(( PHASE >= 5 )) || { log "PHASE=$PHASE - stopping after EC2 provision"; exit 0; }

# ---------- 14. bootstrap each runner via SSM ----------
log "phase 14/15 - SSM bootstrap (install.sh on each runner — ~5 min/runner)"

# install.sh has two upstream-broken things we need to compensate for:
#
# 1. RUNNER REGISTRATION — install.sh POSTs the old admin-shape payload to
#    /api/runners. The current API only accepts {name, regionId} there and
#    rejects the old shape ("regionId must be a string, name must be a
#    string"). We do the registration ourselves against /api/runners with
#    the new shape, save the returned apiKey, and the bootstrap script
#    sed-stubs install.sh's registration curl so it can't fire.
#
# 2. RUNNER BINARY URL — install.sh downloads from $API_URL/runner-amd64,
#    which on app.daytona.io now serves the dashboard SPA's HTML 404 page
#    (Content-Type: text/html). install.sh saves the HTML, chmods +x, and
#    systemd then tries to execve() HTML → "Exec format error". We pre-
#    download the correct binary from the GitHub release matching the API
#    version, place it at /opt/daytona-runner/daytona-runner, and install.sh
#    sees it exists and skips its broken download.

log "  determining Daytona runner binary version to install"
api_version="$(curl -sSI -H "Authorization: Bearer $DAYTONA_API_KEY" \
  "$DAYTONA_API_URL/regions" 2>/dev/null \
  | grep -i '^x-daytona-api-version:' | awk '{print $2}' | tr -d '\r\n ')"
if [[ -z "$api_version" || "$api_version" != v* ]]; then
  log "    couldn't read x-daytona-api-version response header; falling back to GitHub latest"
  api_version="$(curl -fsSL https://api.github.com/repos/daytonaio/daytona/releases/latest \
    | jq -r '.tag_name // empty')"
fi
RUNNER_VERSION="${RUNNER_VERSION:-$api_version}"
[[ -z "$RUNNER_VERSION" ]] && die "could not determine RUNNER_VERSION (override via env if needed)"
RUNNER_BINARY_URL="https://github.com/daytonaio/daytona/releases/download/${RUNNER_VERSION}/runner-amd64"
ok "    runner binary: $RUNNER_VERSION  ($RUNNER_BINARY_URL)"
register_runner() {
  local rname="$1"
  local token_file="$STATE_DIR/runner-token-${rname}.txt"
  local id_file="$STATE_DIR/runner-id-${rname}.txt"
  if [[ -f "$token_file" && -f "$id_file" ]]; then
    cat "$token_file"
    return 0
  fi
  local reg_body http_code
  reg_body="$(curl -sS -o "$STATE_DIR/runner-reg-${rname}.json" -w '%{http_code}' \
    -X POST "$DAYTONA_API_URL/runners" \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$rname\",\"regionId\":\"$REGION_ID\"}")"
  http_code="$reg_body"
  # If 409/duplicate, try to delete by name and retry once
  if [[ "$http_code" == "409" ]] || grep -qiE 'already exists|duplicate|unique' "$STATE_DIR/runner-reg-${rname}.json" 2>/dev/null; then
    warn "    runner '$rname' already exists in Daytona Cloud; deleting + retrying"
    local existing_id
    existing_id="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" \
      | jq -r --arg n "$rname" '.[]? | select(.name==$n) | .id // empty')"
    if [[ -n "$existing_id" ]]; then
      curl -sS -X DELETE -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$DAYTONA_API_URL/runners/$existing_id" >/dev/null || true
      sleep 1
      http_code="$(curl -sS -o "$STATE_DIR/runner-reg-${rname}.json" -w '%{http_code}' \
        -X POST "$DAYTONA_API_URL/runners" \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$rname\",\"regionId\":\"$REGION_ID\"}")"
    fi
  fi
  if [[ ! "$http_code" =~ ^(200|201|204)$ ]]; then
    warn "    POST /runners failed for $rname (HTTP $http_code)"
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
  printf '%s' "$runner_token" > "$token_file"; chmod 600 "$token_file"
  printf '%s' "$runner_id"    > "$id_file"
  echo "$runner_token"
}

for i in "${!RUNNER_INSTANCE_IDS[@]}"; do
  iid="${RUNNER_INSTANCE_IDS[$i]}"
  rname="${RUNNER_NAMES[$i]}"
  rip="${RUNNER_PUBLIC_IPS[$i]}"
  runner_api_url="http://${rip}:3000"

  log "  bootstrapping $rname ($iid, $rip)"

  # Step 1: register the runner ourselves with the API and grab the apiKey.
  if ! runner_token="$(register_runner "$rname")"; then
    warn "    skipping $rname (registration failed); rerun PHASE=5 ./repro.sh"
    continue
  fi
  ok "    registered with Daytona API; token saved to $STATE_DIR/runner-token-${rname}.txt"

  # install.sh expects API_URL to be the HOST ROOT (e.g. https://app.daytona.io)
  # because it appends `/api/config`, `/api/runners`, etc. itself. Our
  # $DAYTONA_API_URL is the full REST base (e.g. https://app.daytona.io/api)
  # because every other curl call in this script needs the /api suffix.
  # Strip the trailing /api when handing the URL to install.sh.
  install_api_url="${DAYTONA_API_URL%/api}"
  install_api_url="${install_api_url%/api/}"

  # Step 2: build the SSM payload. RUNNER_API_KEY is now the apiKey we just
  # received from POST /runners; install.sh will skip its own registration
  # (sed-deleted in runner-bootstrap.sh) and bake this token into the
  # systemd unit as Environment=API_TOKEN=...  RUNNER_BINARY_URL points at
  # the real GitHub-hosted binary since the install.sh-baked URL is broken.
  cat > "$STATE_DIR/runner-payload-${rname}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export API_URL="$install_api_url"
export API_KEY="$DAYTONA_API_KEY"
export RUNNER_API_KEY="$runner_token"
export RUNNER_API_URL="$runner_api_url"
export REGION="$REGION_NAME"
export DOMAIN_OR_IP="$rip"
export PUBLIC_IP="$rip"
export PROCEED="y"
export CONFIRM="y"
export CAPACITY="1000"
export CUSTOM_CPU_COUNT="8"
export CUSTOM_MEMORY_GB="28"
export CUSTOM_DISK_GB="50"
export AWS_REGION="$AWS_REGION"
export AWS_DEFAULT_BUCKET="$S3_BUCKET"
export AWS_ACCESS_KEY_ID="$IAM_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$IAM_SECRET_KEY"
export AWS_ENDPOINT_URL="https://s3.${AWS_REGION}.amazonaws.com"
export RUNNER_BINARY_URL="$RUNNER_BINARY_URL"
EOF
  cat "$SCRIPT_DIR/runner-bootstrap.sh" >> "$STATE_DIR/runner-payload-${rname}.sh"

  # Use --cli-input-json everywhere. Earlier versions had a base64-shortcut
  # path that worked on Linux but produced malformed JSON on macOS (and also
  # mis-handled SSM's `commands` parameter, which expects raw shell strings —
  # not base64). The cli-input-json approach JSON-escapes the entire payload
  # via jq -Rs and is portable + correct.
  payload_json="$(jq -Rs '.' < "$STATE_DIR/runner-payload-${rname}.sh")"
  cat > "$STATE_DIR/ssm-input-${rname}.json" <<JSONEOF
{
  "InstanceIds": ["$iid"],
  "DocumentName": "AWS-RunShellScript",
  "Comment": "daytona BYOC runner bootstrap ($rname)",
  "TimeoutSeconds": 900,
  "Parameters": { "commands": [ $payload_json ] }
}
JSONEOF
  cmd_id="$(AWS_PAGER='' aws ssm send-command \
    --cli-input-json "file://$STATE_DIR/ssm-input-${rname}.json" \
    --output text --query 'Command.CommandId' 2>&1)" || {
    warn "    SSM send-command failed for $rname:"
    echo "$cmd_id" | sed 's/^/      /' >&2
    warn "    rendered JSON saved at: $STATE_DIR/ssm-input-${rname}.json"
    continue
  }
  ok "    SSM command sent: $cmd_id"

  # Poll for completion. Important: every aws CLI call here has AWS_PAGER=''
  # so the output goes straight to stdout/stderr instead of through `less`.
  attempts=0
  while true; do
    status="$(AWS_PAGER='' aws ssm list-commands --command-id "$cmd_id" \
      --query 'Commands[0].Status' --output text 2>/dev/null || true)"
    case "$status" in
      Success)
        echo
        ok "    bootstrap completed for $rname"
        break
        ;;
      Failed|Cancelled|TimedOut)
        echo
        warn "    SSM status=$status for $rname"
        # Save full invocation output to a file so it doesn't blow up the
        # terminal AND nothing is paged. Then print the last 40 lines inline.
        invoke_file="$STATE_DIR/ssm-output-${rname}.json"
        AWS_PAGER='' aws ssm get-command-invocation \
          --command-id "$cmd_id" --instance-id "$iid" \
          --output json > "$invoke_file" 2>/dev/null || true
        echo "    --- StandardErrorContent (last 40 lines) ---" >&2
        jq -r '.StandardErrorContent // ""' < "$invoke_file" 2>/dev/null | tail -40 | sed 's/^/      /' >&2
        echo "    --- StandardOutputContent (last 20 lines) ---" >&2
        jq -r '.StandardOutputContent // ""' < "$invoke_file" 2>/dev/null | tail -20 | sed 's/^/      /' >&2
        echo "    full output saved at: $invoke_file" >&2
        warn "    continuing (rerun PHASE=5 ./repro.sh to retry $rname only)"
        break
        ;;
      InProgress|Pending|Delayed)
        attempts=$((attempts + 1))
        (( attempts > 120 )) && { echo; warn "    SSM still $status after 10 min for $rname"; break; }
        printf '\r    %s SSM %s... %ds' "$rname" "$status" $((attempts * 5))
        sleep 5
        ;;
      *) sleep 5 ;;
    esac
  done
done

log "  giving runners ~30s to call home + report Ready"
sleep 30
runner_resp="$(curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/runners" || true)"
# Match runners by name prefix OR region id (both old .region.id and new
# .regionId shapes). The Daytona /runners response shape has shifted between
# versions, so we keep multiple matchers to stay robust.
echo "$runner_resp" \
  | jq -r --arg p "$RUNNER_NAME_PREFIX" --arg r "$REGION_ID" \
    '.[] | select((.name | startswith($p)) or ((.region // {}).id == $r) or (.regionId == $r))
           | {id, name, state, score: .availabilityScore}' 2>/dev/null \
  || warn "could not parse /runners response - check curl output manually"

# ---------- 14.5 wait for TLS certificates to be Ready ----------
#
# By now, cert-manager has had ~10+ minutes (across phases 12-14) to finish
# DNS-01 + issuance. Most of the time the certs are Ready by now. Occasionally
# Let's Encrypt's order-finalize step returns HTTP 404 (a known LE race —
# both challenges valid, but the finalize URL returns "Certificate not found"
# transiently). When that happens, cert-manager's default backoff is ONE HOUR
# before retry — long enough that the e2e in phase 15 will fail with
# "self-signed certificate" because ingress-nginx is still serving its
# fallback cert.
#
# The reliable recovery is to delete the Certificate (which cleans up the
# stale CertificateRequest/Order/Challenge graph) and re-apply it from the
# manifest we saved in phase 11. That resets the backoff and starts a fresh
# order. DNS-01 has nothing to re-do (records are still valid), so the new
# order usually completes in 20-40 seconds.
log "phase 14.5/15 - waiting for TLS certificates to be Ready"
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

# ---------- 14.6 ECR (private-registry) verification setup ----------
# Provisions an ECR pull-through cache + IAM role with the broker trust
# policy + registers the registry in Daytona. Stage C in e2e.sh then drives
# an actual ECR pull through Daytona's broker flow, giving us live evidence
# for the ECR registry-auth path.
#
# Skip with SKIP_ECR=true if you only care about the declarative builder (S3).
SKIP_ECR="${SKIP_ECR:-false}"
if [[ "$SKIP_ECR" == "true" ]]; then
  log "phase 14.6/15 - SKIP_ECR=true, skipping ECR verification setup"
else
  log "phase 14.6/15 - ECR private-registry setup"
  if DAYTONA_API_KEY="$DAYTONA_API_KEY" \
     DAYTONA_API_URL="$DAYTONA_API_URL" \
     AWS_DEFAULT_REGION="$AWS_REGION" \
     REGION_NAME="$REGION_NAME" \
       bash "$SCRIPT_DIR/ecr-setup.sh"; then
    ok "ECR setup complete"
  else
    warn "ECR setup failed — e2e Stage C will be skipped or show NOT VERIFIED. See output above."
  fi
fi

# ---------- 15. e2e: SDK sandbox creation in our region ----------
if [[ "$SKIP_E2E" == "true" ]]; then
  log "phase 15/15 - SKIP_E2E=true, skipping SDK validation"
else
  log "phase 15/15 - e2e SDK validation in region $REGION_NAME"
  echo "    Three stages run:"
  echo "      Stage A — public-image sandbox (proves proxy + runner basic path)"
  echo "      Stage B — declarative builder (S3 wiring)"
  echo "      Stage C — private ECR pull (registry auth)"
  echo "    After the stages, a VERIFICATION SUMMARY prints"
  echo "    that describes what each stage tested and the evidence for each."
  echo
  if DAYTONA_API_URL="$DAYTONA_API_URL" \
     DAYTONA_API_KEY="$DAYTONA_API_KEY" \
     REGION_NAME="$REGION_NAME" \
     STAGING="$STAGING" \
     S3_BUCKET="$S3_BUCKET" \
       bash "$SCRIPT_DIR/e2e.sh"; then
    ok "e2e SDK validation: all stages passed"
  else
    warn "e2e SDK validation reported issues — see the verification summary above for which stage(s) were not verified"
  fi
fi

# ---------- summary ----------
echo
echo "======================================================================"
echo "  BYOC DEPLOYMENT COMPLETE (AWS)"
echo "======================================================================"
echo "  Daytona Cloud region        : $REGION_NAME (id: $REGION_ID)"
echo "  Region proxy                : https://proxy.$DOMAIN"
echo "  Snapshot manager            : https://snapshots.$DOMAIN"
echo "  S3 bucket                   : $S3_BUCKET ($AWS_REGION)"
echo "  IAM user (snapshots+builder): $IAM_USER_NAME"
echo "  EKS cluster                 : $CLUSTER_NAME ($AWS_REGION)"
echo "  NLB hostname                : $LB_HOSTNAME"
echo "  Runners                     : $RUNNER_COUNT × $RUNNER_INSTANCE_TYPE"
for i in "${!RUNNER_INSTANCE_IDS[@]}"; do
  echo "      - ${RUNNER_NAMES[$i]}  ${RUNNER_INSTANCE_IDS[$i]}  ${RUNNER_PUBLIC_IPS[$i]}"
done
echo
echo "  SDK usage (target the region by name):"
echo "    daytona = Daytona(DaytonaConfig(api_key='...', target='$REGION_NAME'))"
echo "    sandbox = daytona.create()"
echo
echo "  Inspect:"
echo "    kubectl -n $NAMESPACE get pods,svc,ingress,certificate"
echo "    aws ec2 describe-instances --filters 'Name=tag:daytona:region,Values=$REGION_NAME' \\"
echo "        --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,State.Name]' --output table"
echo "    aws ssm start-session --target ${RUNNER_INSTANCE_IDS[0]}"
echo "    curl -H \"Authorization: Bearer \$DAYTONA_API_KEY\" $DAYTONA_API_URL/runners | jq"
echo
echo "  Teardown: $SCRIPT_DIR/teardown.sh"
echo "======================================================================"
