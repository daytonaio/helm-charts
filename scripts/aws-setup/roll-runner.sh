#!/usr/bin/env bash
# scripts/aws-setup/roll-runner.sh — gracefully drain ONE runner before its node
# is rolled, so its sandboxes are NOT stranded.
#
# Why this exists: abruptly terminating a runner's node (e.g. `aws ec2
# terminate-instances`) while it still hosts sandboxes leaves every one of them
# wedged — the dead runner can never finish their start/stop/destroy, and they
# in turn block the runner (and the region) from ever being cleaned up. This
# script does it the safe way for a PLANNED roll, while the runner is still alive:
#
#   1. require >= 2 "ready" runners  (the region must never drop to a single one)
#   2. mark the target runner unschedulable  (no NEW sandboxes land on it)
#   3. STOP each of its sandboxes  -> backs them up to S3 so a peer can restore them
#   4. mark the runner draining    -> Daytona migrates the backed-up sandboxes off
#   5. wait until it holds zero sandboxes
#   6. print the safe node-terminate command (the ASG minSize=2 keeps capacity)
#
# For UNPLANNED loss (a runner that already crashed) the in-chart runnerReaper
# CronJob does steps 2+4 automatically — but it cannot do step 3 (the runner is
# already gone), so those sandboxes only come back if they had a recent backup.
# That is the unavoidable difference between a graceful roll and a crash.
#
# Requires: DAYTONA_API_KEY with read:sandboxes + read/write:runners, IN THE SAME
# ORG as the region. (A wrong-org or read-limited key will list zero sandboxes.)
#
# Usage:
#   ./roll-runner.sh              # list runners in the region
#   ./roll-runner.sh <runner-id>  # gracefully drain that runner
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
[[ -f "$STATE_DIR/prompts.env" ]] && { set -a; . "$STATE_DIR/prompts.env"; set +a; }

omc::need_cmd curl jq kubectl
: "${DAYTONA_API_URL:?set DAYTONA_API_URL (or put it in .state/prompts.env)}"
: "${DAYTONA_API_KEY:?set DAYTONA_API_KEY (read:sandboxes + read/write:runners, same org as the region)}"
NAMESPACE="${NAMESPACE:-daytona}"

# Tiny HTTP helper (mirrors the reaper). Body written to /tmp/rr-body, prints code.
http() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -m 30 -o /tmp/rr-body -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $DAYTONA_API_KEY" -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -sS -m 30 -o /tmp/rr-body -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $DAYTONA_API_KEY" "$url"
  fi
}

# Region id — the reaper reads it from the region-config secret; do the same.
REGION_ID="${REGION_ID:-$(kubectl -n "$NAMESPACE" get secret daytona-region-region-config \
  -o jsonpath='{.data.id}' 2>/dev/null | base64 -d || true)}"
[[ -n "$REGION_ID" ]] || omc::die "REGION_ID not found. Set REGION_ID=... (the *_XXXX region id) and re-run."

# Count ready runners in the region.
[[ "$(http GET "${DAYTONA_API_URL}/runners?regionId=${REGION_ID}")" = 200 ]] \
  || omc::die "GET /runners failed (HTTP): $(cat /tmp/rr-body)"
runners="$(cat /tmp/rr-body)"
ready_count="$(printf '%s' "$runners" | jq '[.[] | select(.state=="ready")] | length')"

RUNNER_ID="${1:-}"
if [[ -z "$RUNNER_ID" ]]; then
  echo "Runners in region ${REGION_ID} (${ready_count} ready):" >&2
  printf '%s' "$runners" | jq -r '.[] | "  \(.id)  \(.name)  state=\(.state)"' >&2
  echo >&2; echo "Usage: $0 <runner-id>" >&2
  exit 0
fi

# Safety gate: never drain below two ready runners.
if [[ "${ready_count:-0}" -lt 2 ]]; then
  omc::die "Only ${ready_count:-0} ready runner(s) — refusing to drain. The region must keep >= 2; scale the 'sandbox' node group up first (minSize/desired >= 2)."
fi
omc::log INFO "Region has ${ready_count} ready runners; draining ${RUNNER_ID} is safe."

# 1) Stop new placement on this runner.
omc::log INFO "Marking ${RUNNER_ID} unschedulable..."
[[ "$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/scheduling" '{"unschedulable":true}')" = 200 ]] \
  || omc::die "scheduling PATCH failed: $(cat /tmp/rr-body)"

# 2) Stop (back up) every sandbox currently on this runner.
list_mine() {
  http GET "${DAYTONA_API_URL}/sandbox?limit=100" >/dev/null
  jq -r --arg r "$RUNNER_ID" '[.items[] | select(.runnerId==$r)]' /tmp/rr-body
}
mine="$(list_mine)"
count="$(printf '%s' "$mine" | jq 'length')"
omc::log INFO "${RUNNER_ID} hosts ${count} sandbox(es); stopping each (this backs them up to S3)..."
printf '%s' "$mine" | jq -r '.[].id' | while IFS= read -r sid; do
  [[ -z "$sid" ]] && continue
  code="$(http POST "${DAYTONA_API_URL}/sandbox/${sid}/stop")"
  omc::log INFO "  stop ${sid} -> HTTP ${code}"
done

# 3) Hand the runner to Daytona's decommission/migration pipeline.
omc::log INFO "Marking ${RUNNER_ID} draining..."
[[ "$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/draining" '{"draining":true}')" = 200 ]] \
  || omc::log WARN "draining PATCH returned: $(cat /tmp/rr-body)"

# 4) Wait until it holds zero sandboxes (stopped/migrated off).
omc::log INFO "Waiting up to ~5 min for ${RUNNER_ID} to reach zero sandboxes..."
left=1
for _ in $(seq 1 30); do
  left="$(list_mine | jq 'length')"
  omc::log INFO "  sandboxes still on ${RUNNER_ID}: ${left}"
  [[ "${left:-0}" -eq 0 ]] && break
  sleep 10
done

if [[ "${left:-1}" -ne 0 ]]; then
  omc::log WARN "${RUNNER_ID} still holds ${left} sandbox(es); do NOT terminate its node yet (they would be stranded). Investigate those sandboxes first."
  exit 1
fi

# 5) Safe to roll the node now.
cat >&2 <<EOF

==================== ${RUNNER_ID} DRAINED ====================
It holds zero sandboxes and is unschedulable+draining. Safe to terminate its
node now — the node group (minSize=2) launches a replacement, so the region
never drops below two runners. Find and terminate the node:

  NODE=\$(kubectl get nodes -l daytona-sandbox-c=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
  # pick the node whose runner is ${RUNNER_ID}, then:
  INSTANCE_ID=\$(kubectl get node <that-node> -o jsonpath='{.spec.providerID}' | sed 's#.*/##')
  aws ec2 terminate-instances --instance-ids "\$INSTANCE_ID" --region "\${AWS_REGION:-us-west-2}"
=============================================================
EOF
