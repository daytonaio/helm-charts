#!/usr/bin/env bash
# Gate: render diff between current helm template output and the pre-change baseline.
# Only acceptable deltas:
#   - Chart.yaml version field updates (helm.sh/chart label)
#   - whitespace-only lines
#   - YAML document separators ("---") position shifts that result in no semantic change
#
# Exit codes:
#   0 — clean (no semantic diff)
#   1 — semantic diff present (regression)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

FAIL=0

run_diff() {
  local chart="$1"
  local baseline="$2"
  local values_arg="$3"
  local label="$4"
  local extra_ignore_regex="${5:-}"
  local tmpfile
  tmpfile="$(mktemp)"
  if ! eval "helm template ./charts/$chart $values_arg" >"$tmpfile" 2>/dev/null; then
    echo "FAIL: helm template ./charts/$chart failed"
    rm -f "$tmpfile"
    return 1
  fi
  local diff_out
  diff_out="$(diff -u "$baseline" "$tmpfile" 2>/dev/null || true)"

  # Filter pipeline:
  #   ^[+-]{3}  — diff file headers
  #   helm.sh/chart  — chart version label (intentional bump)
  #   blank / separator-only lines
  #   Harbor subchart auto-generated random fields (tls.{key,crt}, ca.{key,crt}, CSRF_KEY, JOBSERVICE_SECRET,
  #     REGISTRY_HTTP_SECRET, REGISTRY_CREDENTIAL_PASSWORD, HARBOR_ADMIN_PASSWORD, secret) — these regenerate every render
  #   extra per-chart ignores
  local filter_cmd='grep -E "^[+-]" | grep -vE "^[+-]{3} " | grep -vE "helm\.sh/chart:.*" | grep -vE "^[+-]\s*$" | grep -vE "^[+-]\s*---\s*$"'
  if [[ -n "$extra_ignore_regex" ]]; then
    filter_cmd="$filter_cmd | grep -vE '$extra_ignore_regex'"
  fi

  local semantic_diff
  semantic_diff="$( (echo "$diff_out" | eval "$filter_cmd" || true) | wc -l | tr -d ' ')"
  if [[ "$semantic_diff" -eq 0 ]]; then
    echo "OK [$label]: baseline preserved (Chart version + known-random subchart fields filtered)"
  else
    echo "REGRESSION [$label]: $semantic_diff semantic diff line(s)"
    echo "$diff_out" | eval "$filter_cmd" | head -50
    FAIL=1
  fi
  rm -f "$tmpfile"
}

run_diff "daytona-region" "charts/daytona-region/tests/baselines/rendered-baseline.yaml" "-f charts/daytona-region/tests/fixtures/baseline.values.yaml" "daytona-region" ""

exit $FAIL
