#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC runner bootstrap - runs on each AWS EC2 runner instance
# =============================================================================
#
# Invoked by `aws ssm send-command` from repro.sh after the instance boots.
# Presets every env var that daytona's install.sh checks for, then runs
# install.sh fully non-interactive. install.sh:
#   1. Installs Docker (apt)
#   2. Installs sysbox (apt)
#   3. Downloads the daytona-runner binary to /opt/daytona/runner
#   4. Calls POST /api/runners on the Daytona Cloud API, registering this
#      EC2 instance as a runner under our custom region. Receives a
#      runner-specific dtn_xxx token in the response.
#   5. Writes a systemd unit at /etc/systemd/system/daytona-runner.service
#      with that token baked in as Environment=API_TOKEN=...
#   6. Enables + starts the service.
#
# Inputs (substituted by repro.sh and prepended to this script before sending
# to the instance via SSM):
#   API_URL                 - https://app.daytona.io/api
#   API_KEY                 - your personal dtn_xxx (used to call POST /api/runners)
#   RUNNER_API_URL          - public URL where this runner is reachable (http://<ec2-ip>:3000)
#   REGION                  - name of the custom region we registered via helm
#   CAPACITY                - runner sandbox capacity (integer)
#   CUSTOM_CPU_COUNT        - vCPUs advertised to Daytona for sandbox scheduling
#   CUSTOM_MEMORY_GB        - RAM advertised to Daytona for sandbox scheduling
#   CUSTOM_DISK_GB          - disk advertised to Daytona for sandbox scheduling
#   DOMAIN_OR_IP            - public IP of the EC2 instance
#   PROCEED                 - "y" to skip the first confirmation prompt
#   CONFIRM                 - "y" to skip the Docker-wipe confirmation
#   PUBLIC_IP               - same as DOMAIN_OR_IP
#
# Declarative builder (S3) — must match the values in values-region.yaml:
#   AWS_REGION              - bucket region (e.g. us-east-1)
#   AWS_DEFAULT_BUCKET      - bucket name
#   AWS_ACCESS_KEY_ID       - IAM user access key with R/W on the bucket
#   AWS_SECRET_ACCESS_KEY   - paired secret
#   AWS_ENDPOINT_URL        - https://s3.<region>.amazonaws.com
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

# install.sh has unconditional `read -p "..." < /dev/tty` prompts on top of
# the env-checked ones. Under SSM Run Command there's no tty, so those reads
# would fail and abort install.sh under `set -e`. We patch install.sh
# in-place after download to turn every "< /dev/tty" read into a no-op, then
# rely on the env vars below to provide the values.
export PROCEED="${PROCEED:-y}"
export CONFIRM="${CONFIRM:-y}"          # "y" => install.sh advertises all detected CPU/RAM/disk to Daytona
export CAPACITY="${CAPACITY:-1000}"

# Force install.sh's public IP lookup to use the value we already have, to
# avoid a minute spent calling out to ipinfo.io from inside the VPC.
export PUBLIC_IP="$DOMAIN_OR_IP"

# Builder bucket credentials (consumed by install.sh and baked into the
# systemd unit). Optional - if AWS_ACCESS_KEY_ID is empty install.sh writes
# blanks and the declarative builder will fail with an S3 access error.
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_BUCKET="${AWS_DEFAULT_BUCKET:-}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-https://s3.${AWS_REGION}.amazonaws.com}"

# Ubuntu 22.04 LTS on AWS ships with current CA store + curl + ssm-agent.
# Refresh apt index so the install.sh apt-get installs run cleanly.
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq gnupg lsb-release

# ----------------------------------------------------------------------------
# Pre-install Docker at a pinned version BEFORE running upstream install.sh.
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
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
fi
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu ${LSB_CS} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y

# Install the pinned versions.  --allow-downgrades is harmless on fresh
# instances and necessary if a previous run pulled newer packages.
apt-get install -y --allow-downgrades \
  docker-ce="$DOCKER_PKG" \
  docker-ce-cli="$DOCKER_PKG" \
  containerd.io="$CONTAINERD_PKG"

# Prevent unattended-upgrades or a subsequent `apt-get install docker-ce`
# from silently bumping us back to 29.x.
apt-mark hold docker-ce docker-ce-cli containerd.io

systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker

# Sanity-check the pinned versions actually took.
docker version --format '==> docker {{.Server.Version}}, containerd {{(index .Server.Components 1).Version}}' 2>&1 || true

echo "==> downloading Daytona runner install.sh"
curl -fsSL https://download.daytona.io/install.sh -o /tmp/daytona-install.sh

# Pre-download the actual runner binary from GitHub releases. install.sh's
# baked-in URL ($API_URL/runner-amd64) on app.daytona.io serves the dashboard
# SPA's HTML (Content-Type: text/html) — install.sh would chmod +x the HTML,
# systemd would try to execve() it, and the kernel would refuse with
# "Exec format error" (status 203/EXEC) in an infinite restart loop.
#
# By placing the correct binary at /opt/daytona-runner/daytona-runner FIRST,
# install.sh's "if [ ! -f "$RUNNER_BINARY" ]" check skips its broken download.
: "${RUNNER_BINARY_URL:?RUNNER_BINARY_URL not set (repro.sh should have exported it)}"
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
echo "==> binary verified: $(sudo stat -c%s /opt/daytona-runner/daytona-runner 2>/dev/null || sudo stat -f%z /opt/daytona-runner/daytona-runner) bytes"

# Also kill any stuck daytona-runner service that's restarting in a loop from
# a previous broken-binary attempt. Otherwise install.sh's restart later won't
# pick up the new binary cleanly.
if systemctl list-unit-files daytona-runner.service >/dev/null 2>&1; then
  echo "==> stopping any pre-existing daytona-runner.service (will be re-created by install.sh)"
  sudo systemctl stop daytona-runner 2>/dev/null || true
  sudo systemctl disable daytona-runner 2>/dev/null || true
fi

# Patch install.sh: replace every line ending in `< /dev/tty` with `true`,
# preserving whatever env var was already set. The `${VAR:-default}` lines
# right after each read still apply defaults when an env var is unset.
echo "==> patching install.sh to be non-interactive (no tty under SSM)"
sed -E -i 's|^[[:space:]]*read[[:space:]].*<[[:space:]]*/dev/tty[[:space:]]*$|true # patched: env var preserved|' /tmp/daytona-install.sh
# Confirm the patch took
remaining="$(grep -c '< /dev/tty' /tmp/daytona-install.sh || true)"
if [[ "$remaining" != "0" ]]; then
  echo "WARN: $remaining read(s) still reference /dev/tty after patch - install.sh may hang"
  grep -n '< /dev/tty' /tmp/daytona-install.sh || true
fi

# install.sh's runner-registration block POSTs an old-shape payload to
# /api/runners. The current Daytona API now only accepts {name, regionId}
# there and rejects the old shape with "regionId must be a string, name must
# be a string". repro.sh already did the registration via /api/runners with
# the correct shape and passed us the returned apiKey as RUNNER_API_KEY.
# Replace the install.sh registration curl with a successful no-op so the
# rest of install.sh proceeds and writes the systemd unit using our
# pre-set RUNNER_API_KEY.
echo "==> stubbing out install.sh runner-registration (repro.sh did it via the new API shape)"
python3 - <<'PYEOF'
import re
p = "/tmp/daytona-install.sh"
with open(p) as f:
    content = f.read()
# Use a function for the replacement so the returned string is taken literally —
# string replacements in re.sub interpret backslash escapes (\n, \1, etc.).
# install.sh parses REGISTRATION_RESPONSE with `tail -n1` for the HTTP code and
# `head -n -1` for the body. Setting it to just "200" makes HTTP_STATUS=200
# and RESPONSE_BODY="" which lands in the success branch.
def _replacement(_match):
    return 'REGISTRATION_RESPONSE="200"  # stubbed by aws-repro runner-bootstrap.sh'
new, n = re.subn(
    r'REGISTRATION_RESPONSE=\$\(curl[\s\S]*?\$\{?API_URL\}?/api/runners"\)',
    _replacement,
    content,
)
if n == 0:
    new, n = re.subn(
        r'REGISTRATION_RESPONSE=\$\(curl[\s\S]*?api/runners"\)',
        _replacement,
        content,
    )
with open(p, "w") as f:
    f.write(new)
print(f"  registration stub applied: {n} replacement(s)")
PYEOF
chmod +x /tmp/daytona-install.sh

echo "==> running install.sh (registration is stubbed; install.sh just sets up Docker+sysbox+binary+systemd)"
# Run install.sh but don't let its exit kill our diagnostic block. We capture
# its exit code and exit with it at the very end, AFTER printing diagnostics.
INSTALL_EXIT=0
bash /tmp/daytona-install.sh || INSTALL_EXIT=$?
echo "==> install.sh exit code: $INSTALL_EXIT"

# Whatever install.sh did, give the runner a few seconds to finish starting
# (systemd may report "activating" briefly) before we judge it.
sleep 5

print_diag() {
  echo
  echo "=========================================================="
  echo "  DIAGNOSTIC — daytona-runner.service on this instance"
  echo "=========================================================="
  echo "--- systemctl status (head -40) ---"
  systemctl status daytona-runner --no-pager 2>&1 | head -40 || true
  echo
  echo "--- systemd unit (Environment lines only — secrets redacted) ---"
  if [[ -f /etc/systemd/system/daytona-runner.service ]]; then
    # Redact secret-looking values so they don't end up in SSM output history.
    sed -E 's/(API_TOKEN|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../g' \
      /etc/systemd/system/daytona-runner.service | grep -E '^(\[|Description|ExecStart|Environment=)' | head -40
  else
    echo "(unit file does not exist)"
  fi
  echo
  echo "--- journalctl last 100 lines ---"
  journalctl -u daytona-runner --no-pager -n 100 2>&1 || true
  echo
  echo "--- runner binary ---"
  ls -la /opt/daytona-runner/ 2>&1 || true
  file /opt/daytona-runner/daytona-runner 2>&1 || true
  echo
  echo "--- network reachability to Daytona Cloud ---"
  curl -sS -o /dev/null --max-time 10 \
    -w "  https://app.daytona.io/api -> HTTP %{http_code}\n" \
    https://app.daytona.io/api/regions || true
  echo "=========================================================="
}

if systemctl is-active --quiet daytona-runner; then
  echo "==> daytona-runner.service: ACTIVE"
  echo "==> AWS_* env vars present in unit?"
  grep -E '^Environment=AWS_' /etc/systemd/system/daytona-runner.service \
    | sed -E 's/(SECRET_ACCESS_KEY|ACCESS_KEY_ID)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../' \
    || echo "WARN: AWS_* env vars not present in unit - declarative builder will fail"
  exit 0
fi

echo "==> daytona-runner.service: NOT ACTIVE — dumping diagnostics"
print_diag
# Surface the original install.sh exit code so the SSM run shows Failed.
exit "${INSTALL_EXIT:-1}"
