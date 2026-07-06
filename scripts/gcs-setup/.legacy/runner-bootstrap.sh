#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC runner bootstrap — runs on each GCP runner GCE instance
# =============================================================================
#
# Invoked by `gcloud compute ssh --tunnel-through-iap` from repro.sh after the
# instance boots. The SSH stdin pipeline delivers ONLY non-secret config
# (URLs, region name, machine resource hints, and Secret Manager resource
# names). Every actual secret is pulled at runtime by THIS script using the
# instance's service account.
#
# Specifically, the SSH payload provides Secret Manager resource names:
#   GCP_PROJECT
#   SECRET_HMAC_ACCESS                 # name of GSM secret holding HMAC access key
#   SECRET_HMAC_SECRET                 # name of GSM secret holding HMAC secret
#   SECRET_RUNNER_TOKEN                # name of GSM secret holding this runner's dtn_xxx
#
# The bootstrap then:
#   1. Pre-installs Docker 28.3.3 + containerd 1.7.29 (sysbox v0.6.7 compat;
#      same Docker pinning logic as the AWS repro — see comment block below)
#   2. Pre-downloads the correct daytona-runner ELF from GitHub releases
#      (works around install.sh's broken $API_URL/runner-amd64 download)
#   3. Fetches HMAC + runner token from Secret Manager via the instance SA
#   4. Patches install.sh to be non-interactive AND to skip its own broken
#      runner-registration (repro.sh already did it via the new API shape)
#   5. Runs install.sh, which writes /etc/systemd/system/daytona-runner.service
#      with our secrets baked into Environment= lines (root-only readable)
#   6. Enables + starts the service
#
# After this script returns, the secrets are present on disk in exactly one
# place — the systemd unit file — owned by root and chmod 644 by default.
# A subsequent `chmod 600 /etc/systemd/system/daytona-runner.service` would
# tighten that further; we follow the upstream install.sh default for now.
#
# Inputs (substituted by repro.sh and prepended to this script before piping
# into `gcloud compute ssh`):
#   API_URL                 - https://app.daytona.io (NOT /api — install.sh appends /api)
#   API_KEY                 - your personal dtn_xxx (used by install.sh's
#                             config call and stubbed registration; not embedded
#                             in the unit file)
#   RUNNER_API_URL          - public URL where this runner is reachable
#                             (http://<gce-ip>:3000)
#   REGION                  - name of the custom region we registered via helm
#   CAPACITY                - runner sandbox capacity (integer)
#   CUSTOM_CPU_COUNT        - vCPUs advertised to Daytona for sandbox scheduling
#   CUSTOM_MEMORY_GB        - RAM advertised to Daytona for sandbox scheduling
#   CUSTOM_DISK_GB          - disk advertised to Daytona for sandbox scheduling
#   DOMAIN_OR_IP            - public IP of the GCE instance (or hostname)
#   PROCEED, CONFIRM        - "y" so install.sh skips both confirmation prompts
#   PUBLIC_IP               - same as DOMAIN_OR_IP
#
# Storage (GCS interop) — runner-side must match the chart's storage.s3.* config:
#   AWS_REGION              - bucket location (e.g. us-central1 or us-east1)
#   AWS_DEFAULT_BUCKET      - GCS bucket name
#   AWS_ENDPOINT_URL        - https://storage.googleapis.com   (NOT s3.amazonaws)
#   AWS_ACCESS_KEY_ID       - pulled from Secret Manager by this script
#   AWS_SECRET_ACCESS_KEY   - pulled from Secret Manager by this script
#   AWS_DEFAULT_REGION      - same as AWS_REGION (Daytona's S3 client reads both)
#
# Runner identity:
#   RUNNER_API_KEY          - pulled from Secret Manager by this script
#
# Docker/containerd version pinning (workaround for sysbox v0.6.7 + Docker 29
# time-namespace incompatibility — see the long comment further down):
#   DOCKER_VERSION          - default 28.3.3
#   CONTAINERD_VERSION      - default 1.7.29
# =============================================================================

set -euo pipefail

: "${API_URL:?API_URL not set}"
: "${API_KEY:?API_KEY not set}"
: "${REGION:?REGION not set}"
: "${RUNNER_API_URL:?RUNNER_API_URL not set}"
: "${DOMAIN_OR_IP:?DOMAIN_OR_IP not set}"
: "${GCP_PROJECT:?GCP_PROJECT not set}"
: "${SECRET_HMAC_ACCESS:?SECRET_HMAC_ACCESS not set (Secret Manager resource name)}"
: "${SECRET_HMAC_SECRET:?SECRET_HMAC_SECRET not set (Secret Manager resource name)}"
: "${SECRET_RUNNER_TOKEN:?SECRET_RUNNER_TOKEN not set (Secret Manager resource name)}"
: "${RUNNER_BINARY_URL:?RUNNER_BINARY_URL not set (repro.sh should have exported it)}"

# install.sh has unconditional `read -p "..." < /dev/tty` prompts on top of
# the env-checked ones. Through SSH we have a tty but stdin is the script
# itself, so those reads would consume our script lines. We patch
# install.sh in-place after download to turn every "< /dev/tty" read into a
# no-op, then rely on the env vars below to provide the values.
export PROCEED="${PROCEED:-y}"
export CONFIRM="${CONFIRM:-y}"          # "y" => install.sh advertises all detected CPU/RAM/disk
export CAPACITY="${CAPACITY:-1000}"

# Force install.sh's public IP lookup to use the value we already have.
export PUBLIC_IP="$DOMAIN_OR_IP"

# Container runtime — sysbox-runc is the daytona-runner default.
export CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-sysbox-runc}"

# ----------------------------------------------------------------------------
# Disk resize verification.
#
# GCE shows a "Disk size: '100 GB' is larger than image size: '10 GB'" warning
# at instance-create time because the published Ubuntu Cloud image is 10 GB.
# Ubuntu's cloud-init DOES auto-resize via growpart + resize2fs on first
# boot — but it runs asynchronously and might not be done by the time we
# SSH in.
#
# We do the resize EXPLICITLY here so it's verifiable, not assumed. Both
# tools are idempotent: growpart returns "NOCHANGE" if already at full
# size, and resize2fs no-ops if the FS already matches the partition.
# Output of `df -h /` at the end confirms the actual usable size.
# ----------------------------------------------------------------------------
echo "==> verifying root disk has been resized to fill the volume"
if ! command -v growpart >/dev/null 2>&1; then
  echo "  growpart not found — installing cloud-utils-growpart"
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends cloud-guest-utils >/dev/null
fi
# /dev/sda1 is the root partition on Ubuntu Cloud images. growpart writes
# its decision to stderr in human form; we let it through.
growpart /dev/sda 1 || true
resize2fs /dev/sda1 || true
echo "==> root disk after resize:"
df -h /

# Ubuntu 22.04 LTS on GCE ships with curl + jq + gnupg + lsb-release usually,
# but not always — refresh apt and ensure they're present.
apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl jq gnupg lsb-release file

# ----------------------------------------------------------------------------
# 1. Pre-install Docker at a pinned version BEFORE running upstream install.sh.
#
# Why: upstream install.sh runs `apt-get install -y docker-ce`, which pulls
# whatever is current — at time of writing that's Docker 29.x + containerd
# 2.x. containerd 2.x emits OCI specs with a `time` namespace by default, and
# sysbox-runc v0.6.7 (latest released sysbox) does not support time
# namespaces. The result is that every sandbox start fails with:
#
#     OCI runtime create failed: namespace {"time" ""} does not exist
#
# This affects `docker run --runtime=sysbox-runc` for ANY image — not just
# Daytona-built ones. The fix is to pin Docker to 28.x + containerd to 1.7.x
# (which is also the version Daytona's own docs reference as the supported
# Docker-in-Docker base image, docker:28.3.3-dind).
#
# By installing Docker here, install.sh's `command -v docker` check passes
# and it skips its own Docker install, preserving our pinned versions.
# sysbox install is still handled by install.sh below.
#
# Override DOCKER_VERSION / CONTAINERD_VERSION env vars if/when sysbox v0.7+
# is released and supports time namespaces.
# ----------------------------------------------------------------------------
DOCKER_VERSION="${DOCKER_VERSION:-28.3.3}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.29}"
LSB_RS="$(lsb_release -rs 2>/dev/null || echo 22.04)"
LSB_CS="$(lsb_release -cs 2>/dev/null || echo jammy)"
DOCKER_PKG="5:${DOCKER_VERSION}-1~ubuntu.${LSB_RS}~${LSB_CS}"
CONTAINERD_PKG="${CONTAINERD_VERSION}-1~ubuntu.${LSB_RS}~${LSB_CS}"

echo "==> pre-installing Docker $DOCKER_VERSION + containerd $CONTAINERD_VERSION (sysbox v0.6.7 compat)"

# Set up Docker apt repo (same as upstream install.sh does, but earlier).
if [[ ! -s /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
fi
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu ${LSB_CS} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y

# Install the pinned versions.  --allow-downgrades is harmless on fresh
# instances and necessary if a previous run pulled newer packages.
sudo apt-get install -y --allow-downgrades \
  docker-ce="$DOCKER_PKG" \
  docker-ce-cli="$DOCKER_PKG" \
  containerd.io="$CONTAINERD_PKG"

# Prevent unattended-upgrades or a subsequent `apt-get install docker-ce`
# from silently bumping us back to 29.x.
sudo apt-mark hold docker-ce docker-ce-cli containerd.io

sudo systemctl enable docker >/dev/null 2>&1 || true
sudo systemctl restart docker

# Sanity-check the pinned versions actually took.
docker version --format '==> docker {{.Server.Version}}, containerd {{(index .Server.Components 1).Version}}' 2>&1 || true

# ----------------------------------------------------------------------------
# 2. Pre-download the daytona-runner binary from GitHub releases.
#
# install.sh's baked-in URL ($API_URL/runner-amd64) on app.daytona.io serves
# the dashboard SPA's HTML (Content-Type: text/html) — install.sh would chmod
# +x the HTML, systemd would try to execve() it, and the kernel would refuse
# with "Exec format error" (status 203/EXEC) in an infinite restart loop.
#
# By placing the correct binary at /opt/daytona-runner/daytona-runner FIRST,
# install.sh's "if [ ! -f "$RUNNER_BINARY" ]" check skips its broken download.
# ----------------------------------------------------------------------------
echo "==> pre-downloading runner binary from $RUNNER_BINARY_URL"
sudo mkdir -p /opt/daytona-runner
sudo rm -f /opt/daytona-runner/daytona-runner
sudo curl -fL --max-time 600 -o /opt/daytona-runner/daytona-runner "$RUNNER_BINARY_URL"
sudo chmod +x /opt/daytona-runner/daytona-runner

# Verify the file is actually an ELF binary, not HTML or a 404 page.
if ! sudo file /opt/daytona-runner/daytona-runner | grep -qE 'ELF.*executable'; then
  echo "ERROR: downloaded file is not an ELF binary."
  sudo file /opt/daytona-runner/daytona-runner
  echo "First 200 bytes:"
  sudo head -c 200 /opt/daytona-runner/daytona-runner | xxd | head -5
  exit 1
fi
echo "==> binary verified: $(sudo stat -c%s /opt/daytona-runner/daytona-runner) bytes"

# Kill any stuck daytona-runner service that's restarting in a loop from a
# previous broken-binary attempt. Otherwise install.sh's restart later won't
# pick up the new binary cleanly.
if systemctl list-unit-files daytona-runner.service >/dev/null 2>&1; then
  echo "==> stopping any pre-existing daytona-runner.service"
  sudo systemctl stop daytona-runner 2>/dev/null || true
  sudo systemctl disable daytona-runner 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 3. Fetch secrets from Google Secret Manager using the instance SA.
#
# `gcloud secrets versions access` authenticates via the metadata server,
# so we don't need any explicit credentials here. The instance was created
# with a service account that has roles/secretmanager.secretAccessor scoped
# to exactly these three secrets — nothing else.
#
# We store the values in shell variables locally, write them ONCE into
# install.sh's environment, and then unset them at the end of this script.
# install.sh writes them into the systemd unit's Environment= lines, which
# is the canonical place daytona-runner expects them.
# ----------------------------------------------------------------------------
echo "==> fetching HMAC + runner token from Secret Manager"
if ! command -v gcloud >/dev/null 2>&1; then
  # The Ubuntu LTS GCE images include gcloud preinstalled, but the deep-OS
  # variants don't. Install on the fly if missing.
  echo "  gcloud not on PATH — installing google-cloud-cli"
  sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  sudo apt-get update -y
  sudo apt-get install -y google-cloud-cli
fi

HMAC_ACCESS="$(gcloud secrets versions access latest \
  --secret="$SECRET_HMAC_ACCESS" --project="$GCP_PROJECT")"
HMAC_SECRET="$(gcloud secrets versions access latest \
  --secret="$SECRET_HMAC_SECRET" --project="$GCP_PROJECT")"
RUNNER_API_KEY="$(gcloud secrets versions access latest \
  --secret="$SECRET_RUNNER_TOKEN" --project="$GCP_PROJECT")"

# Sanity: these should be non-empty. We avoid printing them.
[[ -n "$HMAC_ACCESS"    ]] || { echo "ERROR: empty HMAC access key from Secret Manager"; exit 1; }
[[ -n "$HMAC_SECRET"    ]] || { echo "ERROR: empty HMAC secret key from Secret Manager"; exit 1; }
[[ -n "$RUNNER_API_KEY" ]] || { echo "ERROR: empty runner token from Secret Manager";    exit 1; }

# Export for install.sh consumption. NOTE: install.sh expands ${AWS_*:-} so
# unset/empty vars become blanks in the unit. We want non-empty values here.
export AWS_REGION="${AWS_REGION:-us-central1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_DEFAULT_BUCKET="${AWS_DEFAULT_BUCKET:?AWS_DEFAULT_BUCKET not set (GCS bucket name)}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-https://storage.googleapis.com}"
export AWS_ACCESS_KEY_ID="$HMAC_ACCESS"
export AWS_SECRET_ACCESS_KEY="$HMAC_SECRET"
export RUNNER_API_KEY

# ----------------------------------------------------------------------------
# 4. Download + patch + run install.sh.
# ----------------------------------------------------------------------------
echo "==> downloading Daytona runner install.sh"
curl -fsSL https://download.daytona.io/install.sh -o /tmp/daytona-install.sh

# Patch install.sh: replace every line ending in `< /dev/tty` with `true`,
# preserving whatever env var was already set. The `${VAR:-default}` lines
# right after each read still apply defaults when an env var is unset.
echo "==> patching install.sh to be non-interactive"
# This entire script runs under `sudo bash -s` (set in repro.sh phase 14),
# so we're root here. Bare `sed` is fine.
sed -E -i 's|^[[:space:]]*read[[:space:]].*<[[:space:]]*/dev/tty[[:space:]]*$|true # patched: env var preserved|' /tmp/daytona-install.sh
remaining="$(grep -c '< /dev/tty' /tmp/daytona-install.sh || true)"
if [[ "$remaining" != "0" ]]; then
  echo "WARN: $remaining read(s) still reference /dev/tty after patch — install.sh may hang"
fi

# install.sh's runner-registration block POSTs an old-shape payload to
# /api/runners. The current Daytona API only accepts {name, regionId} there
# and rejects the old shape. repro.sh already did the registration via
# /api/runners with the correct shape and passed us the returned apiKey as
# RUNNER_API_KEY. Replace the install.sh registration curl with a successful
# no-op so the rest of install.sh proceeds and writes the systemd unit using
# our pre-set RUNNER_API_KEY.
#
# We write the python program to a temp file rather than piping a heredoc
# into `python3 -`. That avoided a subtle stdin-routing problem we hit
# when this bootstrap ran via `sudo bash -s` over `gcloud compute ssh`:
# the outer bash had already consumed stdin for its script body, and
# `python3 -` couldn't reliably read its heredoc.
echo "==> stubbing install.sh runner-registration (repro.sh did it via the new API shape)"
cat > /tmp/daytona-stub-registration.py <<'PYEOF'
import re, sys
p = "/tmp/daytona-install.sh"
with open(p) as f:
    content = f.read()
def _replacement(_match):
    return 'REGISTRATION_RESPONSE="200"  # stubbed by gcs-repro runner-bootstrap.sh'
new, n = re.subn(
    r'REGISTRATION_RESPONSE=\$\(curl[\s\S]*?\$\{?API_URL\}?/api/runners"\)',
    _replacement, content,
)
if n == 0:
    new, n = re.subn(
        r'REGISTRATION_RESPONSE=\$\(curl[\s\S]*?api/runners"\)',
        _replacement, content,
    )
with open(p, "w") as f:
    f.write(new)
print(f"  registration stub applied: {n} replacement(s)")
PYEOF
python3 /tmp/daytona-stub-registration.py
rm -f /tmp/daytona-stub-registration.py
chmod +x /tmp/daytona-install.sh

echo "==> running install.sh (registration stubbed; install.sh sets up Docker + sysbox + binary + systemd)"
INSTALL_EXIT=0
# `-E` preserves the env vars (PUBLIC_IP, RUNNER_API_KEY, AWS_*, etc.) that
# we set above. Since we're already root, `sudo -E` is functionally equivalent
# to just `env`, but we keep it for parity with install.sh's documented usage.
bash /tmp/daytona-install.sh || INSTALL_EXIT=$?
echo "==> install.sh exit code: $INSTALL_EXIT"

# Don't keep secret-bearing env vars in this shell longer than necessary.
unset HMAC_ACCESS HMAC_SECRET RUNNER_API_KEY \
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# Whatever install.sh did, give the runner a few seconds to finish starting
# before we judge it.
sleep 5

print_diag() {
  echo
  echo "=========================================================="
  echo "  DIAGNOSTIC — daytona-runner.service on this instance"
  echo "=========================================================="
  echo "--- systemctl status (head -40) ---"
  sudo systemctl status daytona-runner --no-pager 2>&1 | head -40 || true
  echo
  echo "--- systemd unit (Environment lines only — secrets redacted) ---"
  if [[ -f /etc/systemd/system/daytona-runner.service ]]; then
    # Redact secret-looking values so they don't end up in SSH output history.
    sudo sed -E 's/(API_TOKEN|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../g' \
      /etc/systemd/system/daytona-runner.service | grep -E '^(\[|Description|ExecStart|Environment=)' | head -40
  else
    echo "(unit file does not exist)"
  fi
  echo
  echo "--- journalctl last 100 lines ---"
  sudo journalctl -u daytona-runner --no-pager -n 100 2>&1 || true
  echo
  echo "--- runner binary ---"
  sudo ls -la /opt/daytona-runner/ 2>&1 || true
  sudo file /opt/daytona-runner/daytona-runner 2>&1 || true
  echo
  echo "--- network reachability to Daytona Cloud ---"
  curl -sS -o /dev/null --max-time 10 \
    -w "  https://app.daytona.io/api/regions -> HTTP %{http_code}\n" \
    https://app.daytona.io/api/regions || true
  echo "=========================================================="
}

if systemctl is-active --quiet daytona-runner; then
  echo "==> daytona-runner.service: ACTIVE"
  echo "==> AWS_* env vars present in unit?"
  sudo grep -E '^Environment=AWS_' /etc/systemd/system/daytona-runner.service \
    | sed -E 's/(SECRET_ACCESS_KEY|ACCESS_KEY_ID)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../' \
    || echo "WARN: AWS_* env vars not present in unit — declarative builder will fail"
  exit 0
fi

echo "==> daytona-runner.service: NOT ACTIVE — dumping diagnostics"
print_diag
exit "${INSTALL_EXIT:-1}"
