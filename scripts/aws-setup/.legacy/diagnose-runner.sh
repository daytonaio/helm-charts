#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC runner diagnostic
# =============================================================================
#
# Runs a read-only diagnostic on a runner EC2 instance via SSM:
#   - systemctl status daytona-runner
#   - the systemd unit's contents (secrets redacted)
#   - journalctl -u daytona-runner (last 200 lines)
#   - the runner binary itself (ls + file)
#   - network reachability to Daytona Cloud's API
#
# Usage:
#   ./diagnose-runner.sh                          # uses the first runner from .state
#   ./diagnose-runner.sh i-0151c47ef099d1353      # specify an instance ID
#   ./diagnose-runner.sh eks-runner-2             # specify a runner name from .state
# =============================================================================

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATE_DIR="$SCRIPT_DIR/.state"

# Resolve the target
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  if [[ -f "$STATE_DIR/runners.env" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/runners.env"
    TARGET="${RUNNER_INSTANCE_IDS[0]}"
    echo "No target specified — defaulting to first runner: $TARGET"
  else
    echo "ERROR: no target and no .state/runners.env found" >&2
    exit 1
  fi
fi
if [[ "$TARGET" =~ ^i-[0-9a-f]+$ ]]; then
  INST="$TARGET"
else
  # Treat as a runner name (e.g. "eks-runner-2"); look up its instance ID by tag
  INST="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$TARGET" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
  if [[ -z "$INST" || "$INST" == "None" ]]; then
    echo "ERROR: could not find an EC2 instance tagged Name=$TARGET" >&2
    exit 1
  fi
  echo "Resolved $TARGET -> $INST"
fi

# Write the diagnostic script to a temp file. Embedding it line-by-line in AWS
# CLI shorthand is fragile; cli-input-json takes a single string literally.
DIAG_SCRIPT="$(mktemp)"
trap 'rm -f "$DIAG_SCRIPT" "$DIAG_SCRIPT".json' EXIT

cat > "$DIAG_SCRIPT" <<'SHELL'
#!/usr/bin/env bash
set +e
sep() { printf '\n========== %s ==========\n' "$1"; }

# Binary info goes FIRST — if the binary is HTML or wrong-arch we want to see
# that before scrolling through hundreds of systemd restart messages.
sep "runner binary"
ls -la /opt/daytona-runner/ 2>&1
echo
sudo file /opt/daytona-runner/daytona-runner 2>&1
echo
echo "first 16 bytes (should start with 7f 45 4c 46 = ELF magic):"
sudo head -c 16 /opt/daytona-runner/daytona-runner 2>&1 | xxd
echo
echo "binary --version (if it can exec at all):"
/opt/daytona-runner/daytona-runner --version 2>&1 || echo "(could not exec)"

sep "systemctl status daytona-runner"
sudo systemctl status daytona-runner --no-pager 2>&1 | head -25

sep "systemd unit (Environment lines, secrets redacted)"
if [[ -f /etc/systemd/system/daytona-runner.service ]]; then
  sudo sed -E 's/(API_TOKEN|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)=([^[:space:]]{8})[^[:space:]]*/\1=\2.../g' \
    /etc/systemd/system/daytona-runner.service \
    | grep -E '^(\[|Description|ExecStart|WorkingDirectory|Environment=|Restart)' \
    | head -50
else
  echo "(no daytona-runner.service unit found)"
fi

sep "network reachability"
curl -sS -o /dev/null --max-time 10 \
  -w "  https://app.daytona.io/api/regions -> HTTP %{http_code} (no auth)\n" \
  https://app.daytona.io/api/regions || true

TOKEN="$(sudo grep -oE 'Environment=API_TOKEN=[^[:space:]]+' \
  /etc/systemd/system/daytona-runner.service 2>/dev/null | head -1 | cut -d= -f3)"
if [[ -n "$TOKEN" ]]; then
  curl -sS -o /dev/null --max-time 10 \
    -w "  https://app.daytona.io/api/regions -> HTTP %{http_code} (with API_TOKEN)\n" \
    -H "Authorization: Bearer $TOKEN" \
    https://app.daytona.io/api/regions || true
fi

sep "docker + sysbox sanity"
docker version 2>&1 | head -10 || echo "docker not working"
echo
sysbox-runc --version 2>&1 || echo "sysbox-runc not found"

# journalctl LAST and only the most recent 30 lines (a restart-loop produces
# hundreds of duplicate lines that bury everything else).
sep "journalctl -u daytona-runner (last 30 lines — restart loops compressed)"
sudo journalctl -u daytona-runner --no-pager -n 30 2>&1

sep "DONE"
SHELL

# Build the SSM cli-input-json payload — single-element commands array.
payload="$(jq -Rs '.' < "$DIAG_SCRIPT")"
cat > "$DIAG_SCRIPT.json" <<JSON
{
  "InstanceIds": ["$INST"],
  "DocumentName": "AWS-RunShellScript",
  "Comment": "daytona-runner diagnostic",
  "TimeoutSeconds": 120,
  "Parameters": { "commands": [ $payload ] }
}
JSON

echo "Sending diagnostic command to $INST..."
CMD_ID="$(aws ssm send-command --cli-input-json "file://$DIAG_SCRIPT.json" \
  --query 'Command.CommandId' --output text)"
echo "CMD_ID=$CMD_ID"

# Poll until terminal status
for i in {1..40}; do
  status="$(aws ssm list-commands --command-id "$CMD_ID" \
    --query 'Commands[0].Status' --output text 2>/dev/null || true)"
  case "$status" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) printf '\r  %s ... %ds' "$status" $((i*3)); sleep 3 ;;
  esac
done
echo

echo
echo "=========================================================="
echo "  DIAGNOSTIC OUTPUT FOR $INST  (final status: $status)"
echo "=========================================================="
aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INST" \
  --query 'StandardOutputContent' --output text
echo
echo "--- StandardErrorContent ---"
aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INST" \
  --query 'StandardErrorContent' --output text
