#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC — end-to-end SDK validation
# =============================================================================
# Drives the Daytona Python SDK against Daytona Cloud, asking it to create a
# sandbox specifically in your custom region (`target=$REGION_NAME`). If the
# region + runner are wired up correctly, the sandbox lands on your Azure VM
# and `print("Hello World from BYOC")` runs there.
#
# Required env (set by repro.sh):
#   DAYTONA_API_URL, DAYTONA_API_KEY, REGION_NAME
# Optional:
#   STAGING - if "true", LE staging certs are in play and the SDK's TLS
#             verification will be turned off via monkey-patch.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.state}"
# Pick up cluster identity + API creds saved by up.sh (.state/prompts.env) so
# the operator can run `bash e2e.sh` right after up.sh without re-exporting.
[[ -f "$STATE_DIR/prompts.env" ]] && { set -a; . "$STATE_DIR/prompts.env"; set +a; }

DAYTONA_API_URL="${DAYTONA_API_URL:?required}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:?required}"
REGION_NAME="${REGION_NAME:?required}"
STAGING="${STAGING:-false}"

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed"; exit 1; }
python3 -c "import daytona" 2>/dev/null || {
  echo "Installing daytona SDK (pip install 'daytona==0.183.*')..."
  python3 -m pip install --quiet --user "daytona==0.183.*" || {
    echo "failed to install daytona SDK; try: pip install 'daytona==0.183.*'"
    exit 1
  }
}

# Build the test script. Has to be a separate python file so we can apply the
# urllib3 monkey-patch before importing daytona.
cat > /tmp/byoc-e2e.py <<PYEOF
import os, sys, ssl

if os.environ.get("STAGING", "false") == "true":
    # LE staging CA is not in any default trust store. For a one-off test
    # we just disable TLS verification globally.
    import urllib3
    from urllib3 import PoolManager
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    ssl._create_default_https_context = ssl._create_unverified_context
    _orig = PoolManager.__init__
    def _patched(self, *a, **k):
        k.setdefault("cert_reqs", "CERT_NONE")
        _orig(self, *a, **k)
    PoolManager.__init__ = _patched

from daytona import Daytona, DaytonaConfig

api_url = os.environ["DAYTONA_API_URL"]
api_key = os.environ["DAYTONA_API_KEY"]
region  = os.environ["REGION_NAME"]

config = DaytonaConfig(api_key=api_key, api_url=api_url, target=region)
client = Daytona(config)

print(f"[e2e] creating sandbox in region: {region}")
sandbox = client.create()
print(f"[e2e] sandbox created: id={sandbox.id}  state={sandbox.state}")

print(f"[e2e] running code in sandbox...")
result = sandbox.process.code_run('print("Hello World from BYOC")')
if result.exit_code == 0:
    print(f"[e2e] PASS - sandbox output: {result.result.strip()}")
    sys.exit(0)
else:
    print(f"[e2e] FAIL - exit={result.exit_code} result={result.result}")
    sys.exit(1)
PYEOF

DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
REGION_NAME="$REGION_NAME" \
STAGING="$STAGING" \
  python3 /tmp/byoc-e2e.py
