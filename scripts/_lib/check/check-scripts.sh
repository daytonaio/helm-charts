#!/usr/bin/env bash
# Gate: shellcheck the setup scripts under scripts/{aws,azure,gcs}-setup/.
# Allowlist info-level findings (SC1091 source paths, SC2034 unused outer vars used by sourced files,
# SC2015 A&&B||C style) because the scripts are operator-side IaC repros, not chart-published surfaces.
# Hard-fail on warning, error, fatal severities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

FAIL=0
EXIT_NONZERO_SCRIPTS=()

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ERROR: shellcheck not installed. Install via 'brew install shellcheck'."
  exit 127
fi

lint_scripts_in_dir() {
  local dir="$1" must_pass="${2:-true}"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  for script in "$dir"/*.sh; do
    [[ -f "$script" ]] || continue
    if ! shellcheck -S warning --exclude=SC2034,SC2015,SC2016,SC1091 "$script" >/dev/null 2>&1; then
      echo "WARNING-level shellcheck findings in $script:"
      shellcheck -S warning --exclude=SC2034,SC2015,SC2016,SC1091 "$script" || true
      if [[ "$must_pass" == "true" ]]; then
        EXIT_NONZERO_SCRIPTS+=("$script")
        FAIL=1
      else
        echo "  ^^ legacy script: warnings tolerated (file slated for removal)"
      fi
    fi
  done
}

if [[ -d "scripts/_lib" ]]; then
  lint_scripts_in_dir "scripts/_lib" true
fi

for dir in scripts/aws-setup scripts/azure-setup scripts/gcs-setup; do
  if [[ ! -d "$dir" ]]; then
    echo "MISSING setup dir: $dir"
    FAIL=1
    continue
  fi
  lint_scripts_in_dir "$dir" true
  if [[ -d "$dir/.legacy" ]]; then
    lint_scripts_in_dir "$dir/.legacy" false
  fi
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: shellcheck warning-level clean for scripts/_lib/ + scripts/{aws,azure,gcs}-setup/*.sh (legacy tolerated)"
else
  echo "FAILED: ${#EXIT_NONZERO_SCRIPTS[@]} script(s) had warning-level findings"
  for s in "${EXIT_NONZERO_SCRIPTS[@]}"; do echo "  $s"; done
fi
exit $FAIL
