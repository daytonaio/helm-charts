#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC runner bootstrap - runs on the Azure runner VM
# =============================================================================
#
# Invoked by `az vm run-command invoke` from repro.sh after the VM boots.
# Presets every env var that daytona's install.sh checks for, then runs
# install.sh fully non-interactive. install.sh:
#   1. Installs Docker (apt)
#   2. Installs sysbox (apt)
#   3. Downloads the daytona-runner binary to /opt/daytona/runner
#   4. Calls POST /api/runners on the Daytona Cloud API, registering this
#      VM as a runner under our custom region. Receives a runner-specific
#      dtn_xxx token in the response.
#   5. Writes a systemd unit at /etc/systemd/system/daytona-runner.service
#      with that token baked in as Environment=API_TOKEN=...
#   6. Enables + starts the service.
#
# Inputs (substituted by repro.sh before sending to the VM):
#   API_URL              - https://app.daytona.io/api
#   API_KEY              - your personal dtn_xxx (used to call POST /api/runners)
#   RUNNER_API_URL       - public URL where this runner is reachable (https://<vm-ip>:3000)
#   REGION               - name of the custom region we registered via helm
#   CAPACITY             - runner sandbox capacity (integer)
#   CUSTOM_CPU_COUNT     - vCPUs available to sandboxes
#   CUSTOM_MEMORY_GB     - RAM available to sandboxes
#   CUSTOM_DISK_GB       - disk available to sandboxes
#   DOMAIN_OR_IP         - public IP of the VM (overrides the install.sh default)
#   PROCEED              - "y" to skip the first confirmation prompt
#   CONFIRM              - "y" to skip the Docker-wipe confirmation
#   PUBLIC_IP            - same as DOMAIN_OR_IP (the install.sh reads either)
# =============================================================================

set -euo pipefail

# All required env vars are set via Environment= in the run-command invocation.
# Failsafe checks below if anything is missing.
: "${API_URL:?API_URL not set}"
: "${API_KEY:?API_KEY not set}"
: "${REGION:?REGION not set}"
: "${RUNNER_API_URL:?RUNNER_API_URL not set}"

# install.sh prompts for these but checks env vars first - presetting all of
# them makes the whole script run unattended.
export PROCEED="${PROCEED:-y}"
export CONFIRM="${CONFIRM:-y}"
export CAPACITY="${CAPACITY:-1000}"
export CUSTOM_CPU_COUNT="${CUSTOM_CPU_COUNT:-2}"
export CUSTOM_MEMORY_GB="${CUSTOM_MEMORY_GB:-8}"
export CUSTOM_DISK_GB="${CUSTOM_DISK_GB:-50}"
export DOMAIN_OR_IP="${DOMAIN_OR_IP:?DOMAIN_OR_IP not set}"

# The install.sh fetches its own PUBLIC_IP via metadata service. Forcing the
# value avoids the lookup taking a minute on Azure.
export PUBLIC_IP="$DOMAIN_OR_IP"

# Daytona runner needs outbound HTTPS to Docker Hub + Daytona API. Make sure
# the latest CA store is present (some Azure VM images ship with stale certs).
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq

echo "==> downloading Daytona runner install.sh"
curl -fsSL https://download.daytona.io/install.sh -o /tmp/daytona-install.sh
chmod +x /tmp/daytona-install.sh

echo "==> running install.sh (this also registers the runner with the Daytona API)"
# Run as the install.sh expects (already root via az vm run-command).
bash /tmp/daytona-install.sh

echo "==> install.sh complete; checking runner service"
systemctl is-active daytona-runner || {
  systemctl status daytona-runner --no-pager
  journalctl -u daytona-runner --no-pager -n 100
  exit 1
}

echo "==> daytona-runner is running"
