#!/usr/bin/env bash
# hack/check-no-install-sh.sh
#
# Guard: ensures the K8s-native BYOC flow has no residual references to
# install.sh-on-node, runner-node SSH, or single-instance install in any
# supported-flow doc, NOTES.txt, or values.yaml comment.
#
# The runner/install.sh file itself is permitted IF it carries a "LEGACY" banner
# at the top of the file. This script does not delete install.sh — it only
# forbids documentation in chart-published surfaces from pointing operators at
# install.sh as the canonical install path.
#
# Exit codes:
#   0 — clean
#   1 — forbidden references found in supported flows
#   2 — runner/install.sh missing the required LEGACY banner
#
# Usage:
#   hack/check-no-install-sh.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0

# Surfaces that MUST NOT mention install.sh-as-canonical or runner-node SSH.
# We grep each surface independently because the allowlist differs.
SUPPORTED_DOC_PATHS=(
  "README.md"
  "charts/daytona-region/README.md"
  "charts/daytona-region/QUICKSTART.md"
  "charts/daytona-region/templates/NOTES.txt"
  "scripts/aws-setup/README.md"
  "scripts/aws-setup/test/README.md"
  "scripts/azure-setup/README.md"
  "scripts/azure-setup/test/README.md"
  "scripts/gcs-setup/README.md"
  "scripts/gcs-setup/test/README.md"
)

# Patterns that signal a non-K8s-native install path.
# Case-insensitive, regex-anchored.
FORBIDDEN_PATTERNS=(
  '\binstall\.sh\b'
  '\brun on the runner node\b'
  '\bsingle[- ]instance install\b'
  '\bssh +(into|to) +(the +)?(runner|compute|node)\b'
  '\bbootstrap +(the +)?(runner +)?node\b'
)

# Grep each supported surface for each forbidden pattern.
for surface in "${SUPPORTED_DOC_PATHS[@]}"; do
  if [[ ! -f "$surface" ]]; then
    # Missing surfaces are fine — chart may not have NOTES.txt yet.
    continue
  fi
  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if grep -niE "$pattern" "$surface" >/dev/null 2>&1; then
      echo "FORBIDDEN reference in supported flow: $surface matches /$pattern/"
      grep -niE "$pattern" "$surface" | sed 's/^/    /'
      FAIL=1
    fi
  done
done

# Confirm the legacy banner is present in runner/install.sh (it remains as a
# legacy artifact, but must self-declare).
LEGACY="runner/install.sh"
LEGACY_BANNER_MARKER="LEGACY"
if [[ -f "$LEGACY" ]]; then
  HEAD_LINES="$(head -n 30 "$LEGACY")"
  if ! grep -q "$LEGACY_BANNER_MARKER" <<<"$HEAD_LINES"; then
    echo "MISSING LEGACY banner in $LEGACY (first 30 lines must contain '$LEGACY_BANNER_MARKER')"
    FAIL=2
  fi
fi

# values.yaml comments must NOT instruct operators to ssh into the node.
for chart in charts/daytona-region; do
  if [[ -f "$chart/values.yaml" ]]; then
    for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
      if grep -niE "$pattern" "$chart/values.yaml" >/dev/null 2>&1; then
        echo "FORBIDDEN reference in $chart/values.yaml matches /$pattern/"
        grep -niE "$pattern" "$chart/values.yaml" | sed 's/^/    /'
        FAIL=1
      fi
    done
  fi
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: no forbidden install.sh-on-node / runner-SSH references in supported flows."
fi

exit $FAIL
