#!/usr/bin/env bash
# scripts/azure-setup/migrate-oss-to-byoc.sh
#
# Migrate a cluster running the full self-hosted OSS deployment (Helm release
# of charts/daytona: api + dex + postgres + harbor + proxy + runners) to BYOC
# (charts/daytona-region: compute only, control plane at Daytona Cloud),
# REUSING the existing Let's Encrypt wildcard cert so NO new TLS is issued.
#
# REQUIRED:
#   export DAYTONA_CLOUD_API_KEY='dtn_...'   # a Daytona Cloud (app.daytona.io) API key
#   export REGION_NAME='my-region'           # the custom region name to register
# then:
#   CONFIRM=yes scripts/azure-setup/migrate-oss-to-byoc.sh
# (Run WITHOUT CONFIRM=yes first to dry-run only — it renders + validates cert
#  reuse and performs NO teardown.)
#
# AUTO-DETECTED from the live OSS release (override via env if detection fails):
#   NS            namespace of the OSS release                  (default: daytona)
#   OSS_RELEASE   name of the OSS Helm release                  (default: daytona)
#   BYOC_RELEASE  name of the BYOC release to install           (default: daytona-region)
#   BASE_DOMAIN   from `helm get values <oss>` .baseDomain
#   CERT_SECRET   ${BASE_DOMAIN}-tls — the OSS api-ingress secret that covers
#                 BOTH the apex domain and *.${BASE_DOMAIN} (OSS chart convention)
#
# OPTIONAL:
#   STORAGE_CLASS       storageClass for the snapshot registry PVC (default:
#                       cluster default storage class)
#   SNAPSHOT_PVC_SIZE   registry PVC size (default: 64Gi)
#   PRUNE_PVCS=yes      delete the OSS PVCs (postgres/redis/dex/harbor) after
#                       uninstall — their data is control-plane state that BYOC
#                       does not use. Harbor-subchart PVCs without instance
#                       labels may still need manual cleanup.
#
# RUNNER BACKUP STORAGE (S3-shaped; used by runners for sandbox backups and
# build context — the snapshot REGISTRY does not use it, see below). One of:
#   a) $STATE_DIR/byoc-storage.env exists (Azure: written when the rclone
#      gateway over Azure Blob was provisioned — see rclone-deployment.yaml.tmpl)
#   b) export RUNNER_S3_ENDPOINT/RUNNER_S3_BUCKET/RUNNER_S3_ACCESS_KEY/
#      RUNNER_S3_SECRET_KEY[/RUNNER_S3_REGION] for any real S3-compatible store
#   c) SKIP_RUNNER_STORAGE=yes — install without it (sandbox backups/volumes
#      stay disabled until storage is configured; runner boots via the
#      allowEmptyStaticKeyShim).
#
# CERT REUSE (no re-issue):
#   - the OSS cert secret (${BASE_DOMAIN}-tls, covering ${BASE_DOMAIN} and
#     *.${BASE_DOMAIN}) is cert-manager-owned with no ownerRef -> it survives
#     `helm uninstall`.
#   - proxyUrl = https://${BASE_DOMAIN} makes the BYOC proxy ingress reference
#     that exact secret; selfSigned=false + no issuer annotations => no
#     re-issue, no clobber (proxy-tls-secrets only renders for selfSigned/PEM).
#   - the snapshot ingress wants snapshots.${BASE_DOMAIN}-tls; the wildcard
#     covers that host, so we COPY the existing secret under that name.
#
# SNAPSHOT REGISTRY STORAGE: the BYOC snapshot-manager (a docker registry) runs
# on its FILESYSTEM driver with a PVC. Do NOT point it at an S3 shim (rclone
# gateway, GCS interop): the registry s3 driver (distribution v3) resumes blob
# uploads via ListMultipartUploads and nil-panics on the stub responses shims
# return (=> 502s on push, snapshots stuck in error). OSS Harbor snapshot
# images are NOT migrated — snapshots are rebuilt on first use in the region.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHART="$REPO_ROOT/charts/daytona-region"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.state}"
mkdir -p "$STATE_DIR"

# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

NS="${NS:-daytona}"
OSS_RELEASE="${OSS_RELEASE:-daytona}"
BYOC_RELEASE="${BYOC_RELEASE:-daytona-region}"
DAYTONA_CLOUD_API_URL="${DAYTONA_CLOUD_API_URL:-https://app.daytona.io/api}"
SNAPSHOT_PVC_SIZE="${SNAPSHOT_PVC_SIZE:-64Gi}"

# ---- 0. tooling + creds -----------------------------------------------------
for c in kubectl helm jq curl openssl ssh-keygen base64; do
  command -v "$c" >/dev/null || die "$c not found"
done
[[ -n "${DAYTONA_CLOUD_API_KEY:-}" ]] || die "set DAYTONA_CLOUD_API_KEY (a Daytona Cloud app.daytona.io API key) — BYOC has no control plane without it"
[[ -n "${REGION_NAME:-}" ]]          || die "set REGION_NAME (the custom region to register with Daytona Cloud)"
helm status "$OSS_RELEASE" -n "$NS" >/dev/null 2>&1 \
  || die "OSS Helm release '$OSS_RELEASE' not found in ns '$NS' (override NS / OSS_RELEASE if yours differ)"

# ---- 0b. detect the OSS deployment's domain + cert --------------------------
if [[ -z "${BASE_DOMAIN:-}" ]]; then
  BASE_DOMAIN="$(helm get values "$OSS_RELEASE" -n "$NS" -o json 2>/dev/null | jq -r '.baseDomain // empty')"
fi
[[ -n "${BASE_DOMAIN:-}" ]] \
  || die "could not detect baseDomain from 'helm get values $OSS_RELEASE'; export BASE_DOMAIN=<your OSS base domain>"
CERT_SECRET="${CERT_SECRET:-${BASE_DOMAIN}-tls}"
PROXY_URL="${PROXY_URL:-https://${BASE_DOMAIN}}"
SNAPSHOT_HOSTNAME="${SNAPSHOT_HOSTNAME:-snapshots.${BASE_DOMAIN}}"
SNAPSHOT_CERT="${SNAPSHOT_HOSTNAME}-tls"

echo "kube context : $(kubectl config current-context)"
echo "oss release  : $OSS_RELEASE (ns $NS)  ->  byoc release: $BYOC_RELEASE"
echo "base domain  : $BASE_DOMAIN  (cert secret: $CERT_SECRET)"
echo "region       : $REGION_NAME -> $DAYTONA_CLOUD_API_URL"
echo "proxy / snap : $PROXY_URL  |  https://$SNAPSHOT_HOSTNAME"

# ---- 0c. runner backup storage (S3-shaped) ----------------------------------
RUNNER_STORAGE_MODE=""
if [[ -f "$STATE_DIR/byoc-storage.env" ]]; then
  # Azure flow: rclone S3 gateway over Azure Blob, provisioned earlier.
  # shellcheck disable=SC1091
  set -a; . "$STATE_DIR/byoc-storage.env"; set +a   # BLOB_BUCKET, RCLONE_*, RCLONE_GATEWAY_ENDPOINT
  RUNNER_S3_ENDPOINT="${RUNNER_S3_ENDPOINT:-$RCLONE_GATEWAY_ENDPOINT}"
  RUNNER_S3_BUCKET="${RUNNER_S3_BUCKET:-$BLOB_BUCKET}"
  RUNNER_S3_ACCESS_KEY="${RUNNER_S3_ACCESS_KEY:-$RCLONE_ACCESS_KEY}"
  RUNNER_S3_SECRET_KEY="${RUNNER_S3_SECRET_KEY:-$RCLONE_SECRET_KEY}"
fi
if [[ -n "${RUNNER_S3_BUCKET:-}" && -n "${RUNNER_S3_ACCESS_KEY:-}" && -n "${RUNNER_S3_SECRET_KEY:-}" ]]; then
  RUNNER_STORAGE_MODE="s3"
  RUNNER_S3_REGION="${RUNNER_S3_REGION:-us-east-1}"
  echo "runner store : s3://$RUNNER_S3_BUCKET via ${RUNNER_S3_ENDPOINT:-<aws default endpoint>}"
elif [[ "${SKIP_RUNNER_STORAGE:-}" == "yes" ]]; then
  RUNNER_STORAGE_MODE="none"
  echo "runner store : NONE (SKIP_RUNNER_STORAGE=yes — sandbox backups/volumes disabled)"
else
  die "no runner backup storage configured. Either provision it (Azure: rclone \
gateway writing $STATE_DIR/byoc-storage.env), export RUNNER_S3_* for an \
S3-compatible store, or set SKIP_RUNNER_STORAGE=yes to proceed without it."
fi

# ---- 1. preserve the cert: verify + back up ---------------------------------
kubectl -n "$NS" get secret "$CERT_SECRET" >/dev/null 2>&1 \
  || die "cert secret $CERT_SECRET not found (override CERT_SECRET if your OSS TLS secret is named differently)"
EXP="$(kubectl -n "$NS" get secret "$CERT_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate | sed 's/notAfter=//')"
echo "cert $CERT_SECRET expires: $EXP"
kubectl -n "$NS" get secret "$CERT_SECRET" -o yaml > "$STATE_DIR/${CERT_SECRET}.backup.yaml"

# ---- 2. values overlay (cert reuse + storage + Cloud creds) ------------------
# SSH: the gateway needs a client keypair + gateway host key (values are base64
# of the key FILES, per QUICKSTART) and the runners need the matching base64
# client pubkey in SSH_PUBLIC_KEY — otherwise the gateway crashloops on empty
# keys and sandboxes silently refuse gateway SSH. Keys persist in .state/ and
# are reused on re-runs.
omc::ssh_keys_ensure "$STATE_DIR"

# Optional global.storageClass block — omitted when STORAGE_CLASS is empty so
# the snapshot registry PVC binds with the cluster's default storage class.
GLOBAL_BLOCK=""
if [[ -n "${STORAGE_CLASS:-}" ]]; then
  GLOBAL_BLOCK="global:
  storageClass: \"${STORAGE_CLASS}\""
fi

# Runner env + credential mode, depending on backup storage availability.
if [[ "$RUNNER_STORAGE_MODE" == "s3" ]]; then
  RUNNER_BLOCK="    aws:
      credentialMode: \"static\"
      allowEmptyStaticKeyShim: false
    env:
      AWS_REGION: \"${RUNNER_S3_REGION}\"
      AWS_ENDPOINT_URL: \"${RUNNER_S3_ENDPOINT:-}\"
      AWS_DEFAULT_BUCKET: \"${RUNNER_S3_BUCKET}\"
      AWS_ACCESS_KEY_ID: \"${RUNNER_S3_ACCESS_KEY}\"
      AWS_SECRET_ACCESS_KEY: \"${RUNNER_S3_SECRET_KEY}\"
      # Must be the base64 of the SAME client pubkey the gateway holds, or
      # sandboxes won't authorize gateway connections (silent SSH-only failure).
      SSH_PUBLIC_KEY: \"${PUB_CLIENT_B64}\""
else
  RUNNER_BLOCK="    aws:
      credentialMode: \"static\"
      # No backup storage configured (SKIP_RUNNER_STORAGE=yes): emit empty AWS
      # keys so the upstream runner config validator does not block startup.
      # Sandbox backups/volumes stay disabled until real storage is configured.
      allowEmptyStaticKeyShim: true
    env:
      SSH_PUBLIC_KEY: \"${PUB_CLIENT_B64}\""
fi

VALUES="$STATE_DIR/values-byoc-migrate.yaml"
cat > "$VALUES" <<YAML
regionName: "${REGION_NAME}"
proxyUrl: "${PROXY_URL}"
baseDomain: "${BASE_DOMAIN}"
daytonaApiUrl: "${DAYTONA_CLOUD_API_URL}"
daytonaApiKey: "${DAYTONA_CLOUD_API_KEY}"
# Advertised to Daytona Cloud by the registration hook; without this the chart
# helper registers the unroutable http://snapshots.daytona.local:5000 default
# and every snapshot push from runners fails on DNS.
snapshotManagerUrl: "https://${SNAPSHOT_HOSTNAME}"
${GLOBAL_BLOCK}
registration:
  enabled: true
services:
  proxy:
    ingress:
      enabled: true
      className: "nginx"
      tls: true
      selfSigned: false
      # No cert-manager issuer => reuse the existing ${CERT_SECRET}, no re-issue.
      annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
        nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
        nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
        # Build contexts and uploads exceed nginx's 1m default body limit.
        nginx.ingress.kubernetes.io/proxy-body-size: "0"
        nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
  snapshotManager:
    enabled: true
    ingress:
      enabled: true
      className: "nginx"
      hostname: "${SNAPSHOT_HOSTNAME}"
      tls: true
      # No issuer => reuse the copied ${SNAPSHOT_CERT} (same wildcard cert).
      annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
        # Docker layer pushes exceed nginx's 1m default body limit (413).
        nginx.ingress.kubernetes.io/proxy-body-size: "0"
        nginx.ingress.kubernetes.io/proxy-read-timeout: "900"
        nginx.ingress.kubernetes.io/proxy-send-timeout: "900"
    storage:
      # Registry data on a PVC — see the header for why an S3 shim cannot back
      # the registry (multipart-resume nil-panic).
      driver: "filesystem"
      filesystem:
        persistence:
          enabled: true
          size: ${SNAPSHOT_PVC_SIZE}
      deleteEnabled: true
  sshGateway:
    # BOOTSTRAP value only. The gateway Bearer-validates SSH sessions against
    # the cloud and needs the REGION-SCOPED key (the org key 403s on
    # ValidateSshAccess) — that key only exists after registration, so the
    # post-install step swaps it in (omc::region_sshgateway_finalize).
    apiKey: "${DAYTONA_CLOUD_API_KEY}"
    sshKeys:
      privClientSSHKey: "${PRIV_CLIENT_B64}"
      pubClientSSHKey: "${PUB_CLIENT_B64}"
      privGatewaySSHKey: "${PRIV_GATEWAY_B64}"
  runner:
    # Sidecar-only host prep: the runnermanager spawns the real runner pods
    # (they envFrom runner-config/runner-secrets and bind hostPorts 3000/2220).
    # A static mainContainer runner never registers with the cloud and would
    # fight the manager's pods for those hostPorts.
    mainContainer:
      enabled: false
${RUNNER_BLOCK}
YAML
echo "wrote $VALUES"

# ---- 3. dry-run render + assert NO re-issue / NO clobber --------------------
echo "=== Dry-run render (validates BEFORE any teardown) ==="
helm template "$BYOC_RELEASE" "$CHART" -n "$NS" -f "$VALUES" > "$STATE_DIR/byoc-render.yaml" \
  || die "helm template failed — fix values; nothing was torn down"
grep -qiE 'cert-manager\.io/(cluster-)?issuer' "$STATE_DIR/byoc-render.yaml" \
  && die "render references a cert-manager issuer => would re-issue TLS. Aborting."
grep -q "$CERT_SECRET" "$STATE_DIR/byoc-render.yaml" \
  || die "render does not reference $CERT_SECRET (proxy cert reuse not wired). Aborting."
# clobber guard: the chart must NOT emit a Secret named like the existing certs
if awk '/^kind: Secret$/{s=1} s&&/^  name: /{print $2; s=0}' "$STATE_DIR/byoc-render.yaml" \
     | grep -qxE "${CERT_SECRET}|${SNAPSHOT_CERT}"; then
  die "render emits a Secret named ${CERT_SECRET}/${SNAPSHOT_CERT} => would overwrite your real cert. Aborting."
fi
echo "OK: reuses $CERT_SECRET, issues no new cert, does not overwrite the cert secret."

[[ "${CONFIRM:-}" == "yes" ]] || { echo; echo "Dry-run passed. Re-run with CONFIRM=yes to perform the DESTRUCTIVE migration."; exit 0; }

# ---- 4. teardown OSS (cert + cert-manager + ingress-nginx survive) ----------
echo "=== helm uninstall $OSS_RELEASE (OSS control plane) ==="
helm uninstall "$OSS_RELEASE" -n "$NS" --wait --timeout 10m
kubectl -n "$NS" get secret "$CERT_SECRET" >/dev/null 2>&1 \
  || { echo "restoring cert from backup"; kubectl apply -f "$STATE_DIR/${CERT_SECRET}.backup.yaml"; }
# OSS control-plane PVCs (postgres/redis/dex/harbor) hold state BYOC never
# reads. Opt-in cleanup; harbor-subchart PVCs without instance labels may
# remain and can be deleted manually.
[[ "${PRUNE_PVCS:-}" == "yes" ]] && kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=$OSS_RELEASE" --ignore-not-found

# ---- 5. copy wildcard cert -> snapshots host name (same cert, no re-issue) --
kubectl -n "$NS" get secret "$CERT_SECRET" -o json \
  | jq --arg n "$SNAPSHOT_CERT" 'del(.metadata.ownerReferences,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.annotations,.metadata.labels) | .metadata.name=$n' \
  | kubectl apply -f -
echo "copied $CERT_SECRET -> $SNAPSHOT_CERT (reuses the same wildcard cert)"

# ---- 6. deploy BYOC ----------------------------------------------------------
echo "=== helm install $BYOC_RELEASE (BYOC) ==="
helm install "$BYOC_RELEASE" "$CHART" -n "$NS" -f "$VALUES" --wait --timeout 15m

# ---- 6b. ssh-gateway region key + sshGatewayUrl (post-registration only) -----
# The region-scoped ssh-gateway key cannot exist before the hook registers the
# region; the helper fetches it, rolls it into the release via a persisted
# overlay, bounces the gateway pod, and advertises the gateway LB to the cloud.
omc::region_sshgateway_finalize "$NS" "$BYOC_RELEASE" "$CHART" "$VALUES" \
  "$DAYTONA_CLOUD_API_URL" "$DAYTONA_CLOUD_API_KEY"

# ---- 7. verify ----------------------------------------------------------------
echo "=== post-migration ==="
kubectl -n "$NS" get pods
echo "Certificates (should show only old names; no new proxy/snapshot cert issued):"
kubectl -n "$NS" get certificate 2>/dev/null || true
cat <<EOF
Done. BYOC region '${REGION_NAME}' deployed; TLS served from the preserved $CERT_SECRET.

Next: create a snapshot in this region, then a sandbox from it (dashboard or API).
Future manual upgrades MUST pass both values files or SSH breaks:
  helm upgrade $BYOC_RELEASE charts/daytona-region -n $NS \\
    -f $VALUES \\
    -f $STATE_DIR/values-sshgateway-key.yaml
EOF
