#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC (GCP) — snapshot-creation diagnostic
# =============================================================================
#
# Runs 7 read-only checks against your BYOC deployment to pin down where a
# dashboard "Create Snapshot" 500 is coming from:
#
#   1. List BYOC runner VMs + their zones (project-wide, label-based)
#   2. Docker Hub pull test from each runner (catches rate-limiting)
#   3. systemd unit envs on each runner (verifies snapshot-mgr basic-auth
#      + GCS HMAC creds are baked in)
#   4. systemctl status + last 60 lines of daytona-runner logs
#   5. snapshot-manager pod status + last 100 log lines
#   6. proxy pod status + last 100 log lines
#   7. snapshot-manager → GCS env-var sanity (bucket / endpoint / region)
#
# All output is to stdout/stderr; nothing is mutated. Re-run any time.
#
# Required env:
#   GCP_PROJECT      your GCP project ID (matches what repro.sh used)
#
# Optional env:
#   NAMESPACE        default daytona-region
#   RUNNER_NAME_RE   filter for runner names; default ^gke-runner-
#
# Usage:
#   ./diagnose-snapshot.sh
#   ./diagnose-snapshot.sh 2>&1 | tee /tmp/diag.log    # capture for later
# =============================================================================

set +e   # NEVER abort on a single check; we want all 7 to run

GCP_PROJECT="${GCP_PROJECT:?GCP_PROJECT env var is required}"
NAMESPACE="${NAMESPACE:-daytona-region}"
RUNNER_NAME_RE="${RUNNER_NAME_RE:-^gke-runner-}"

command -v gcloud  >/dev/null 2>&1 || { echo "gcloud not on PATH" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not on PATH" >&2; exit 1; }

echo
echo "─── 1. BYOC runners + zones (project-wide, by label+name) ──────────────"
gcloud compute instances list --project="$GCP_PROJECT" \
  --filter="labels.managed-by=gcs-repro AND name~$RUNNER_NAME_RE" \
  --format='table(name,zone.basename(),status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)'

runners_tsv="$(gcloud compute instances list --project="$GCP_PROJECT" \
  --filter="labels.managed-by=gcs-repro AND name~$RUNNER_NAME_RE" \
  --format='value(name,zone.basename())')"

if [[ -z "$runners_tsv" ]]; then
  echo "  No BYOC runner VMs found. Either teardown ran, or labels are missing."
  echo "  Try: gcloud compute instances list --project=$GCP_PROJECT"
  exit 1
fi

echo
echo "─── 2. Docker Hub pull test (catches rate-limiting / network issues) ──"
echo "    If you see TOOMANYREQUESTS or 'pull access denied', the dashboard"
echo "    500 is almost certainly Docker Hub rate limiting on your runners'"
echo "    public IPs. Fix: register a Docker Hub credential in Daytona, or"
echo "    use a different base image, or wait ~1h for the limit to reset."
echo
while IFS=$'\t' read -r rname rzone; do
  [[ -z "$rname" ]] && continue
  echo "→ $rname ($rzone):"
  gcloud compute ssh "$rname" --project="$GCP_PROJECT" --zone="$rzone" \
    --tunnel-through-iap --ssh-flag="-q" \
    --command 'sudo docker pull --quiet ubuntu:22.04 2>&1 | head -5; sudo docker rmi ubuntu:22.04 >/dev/null 2>&1; true' \
    2>&1 | sed 's/^/    /'
done <<< "$runners_tsv"

echo
echo "─── 3. systemd unit env vars on each runner (secrets redacted) ────────"
echo "    Must see ALL of: API_TOKEN, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,"
echo "    AWS_DEFAULT_BUCKET, AWS_ENDPOINT_URL. Missing AWS_* → no snapshot"
echo "    storage. Missing API_TOKEN → runner can't reach Daytona Cloud."
echo
while IFS=$'\t' read -r rname rzone; do
  [[ -z "$rname" ]] && continue
  echo "→ $rname ($rzone):"
  gcloud compute ssh "$rname" --project="$GCP_PROJECT" --zone="$rzone" \
    --tunnel-through-iap --ssh-flag="-q" \
    --command 'sudo sed -E "s/(API_TOKEN|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|PASSWORD)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../g" /etc/systemd/system/daytona-runner.service 2>/dev/null | grep -E "^Environment=" | head -30' \
    2>&1 | sed 's/^/    /'
done <<< "$runners_tsv"

echo
echo "─── 4. daytona-runner service status + last 60 log lines ──────────────"
echo "    Look for: 'OCI runtime create failed: namespace {time \"\"}' (sysbox"
echo "    + docker 29 incompat), '403 Forbidden' on GCS, 'failed to inspect"
echo "    image' (registry issue), or any panic/fatal."
echo
while IFS=$'\t' read -r rname rzone; do
  [[ -z "$rname" ]] && continue
  echo "→ $rname ($rzone):"
  gcloud compute ssh "$rname" --project="$GCP_PROJECT" --zone="$rzone" \
    --tunnel-through-iap --ssh-flag="-q" \
    --command 'echo "is-active: $(sudo systemctl is-active daytona-runner)"; echo "---"; sudo journalctl -u daytona-runner -n 60 --no-pager 2>&1 | tail -60' \
    2>&1 | sed 's/^/    /'
done <<< "$runners_tsv"

echo
echo "─── 5. snapshot-manager pod state + last 100 log lines ────────────────"
echo "    Look for: 'access denied' or 'signature mismatch' (HMAC stale),"
echo "    'NoSuchBucket' (wrong bucket name), '401 Unauthorized' on inbound"
echo "    requests (runner using wrong snapshot-manager credentials)."
echo
kubectl -n "$NAMESPACE" get pods -o wide 2>&1 | sed 's/^/    /'
echo "    ─── logs ────────────────────────────────────────────"
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/component=snapshot-manager --tail=100 2>&1 | sed 's/^/      /' | tail -120

echo
echo "─── 6. proxy pod status + last 100 log lines ──────────────────────────"
echo "    Look for: 'no runners available', 'runner not ready', '5xx upstream'."
echo
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/component=proxy --tail=100 2>&1 | sed 's/^/      /' | tail -120

echo
echo "─── 7. snapshot-manager → GCS env (bucket / endpoint / region) ────────"
sm_pod="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/component=snapshot-manager -o name 2>/dev/null | head -1)"
if [[ -n "$sm_pod" ]]; then
  echo "    pod: $sm_pod"
  kubectl -n "$NAMESPACE" exec "$sm_pod" -- env 2>/dev/null \
    | grep -E '^SNAPSHOT_MANAGER_(STORAGE_S3_|AUTH_TYPE)' \
    | sed 's/PASSWORD=.*/PASSWORD=.../;s/SECRETKEY=.*/SECRETKEY=.../;s/ACCESSKEY=\(.\{8\}\).*/ACCESSKEY=\1.../' \
    | sort | sed 's/^/    /'
else
  echo "    no snapshot-manager pod found in namespace $NAMESPACE"
fi

echo
echo "─── diagnostic complete ───────────────────────────────────────────────"
echo
echo "Paste the relevant section above (or the whole output) and we can"
echo "pinpoint the cause of the dashboard 500."
