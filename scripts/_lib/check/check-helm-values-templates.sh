#!/usr/bin/env bash
# Static QA gate: render each scripts/<cloud>-setup/values-region.yaml.tmpl
# with its matching test/fixtures/byoc-prompt-set-<cloud>.env, then helm template +
# helm lint against charts/daytona-region to confirm the rendered values are valid
# for the K8s-native chart surface.
# This is the STATIC SUBSTITUTE for cloud QA — operator runs real-cloud separately.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

FAIL=0

check_template() {
  local label="$1" tmpl="$2" fixture="$3" chart="$4"
  echo ""
  echo "=== $label ==="
  if [[ ! -f "$tmpl" ]]; then
    echo "MISSING template: $tmpl"
    FAIL=1
    return
  fi
  if [[ ! -f "$fixture" ]]; then
    echo "MISSING fixture: $fixture"
    FAIL=1
    return
  fi

  local out
  out="$(mktemp -t byoc-values-XXXXXX.yaml)"
  (
    set -a
    # shellcheck disable=SC1090
    . "$fixture"
    set +a
    envsubst < "$tmpl" > "$out"
  )

  local remaining
  remaining="$(grep -c '\${' "$out" 2>/dev/null || true)"
  if [[ "$remaining" -gt 0 ]]; then
    echo "FAIL [$label]: $remaining unresolved \${...} placeholders after envsubst"
    grep -nE '\${' "$out" | head -10
    rm -f "$out"
    FAIL=1
    return
  fi

  if ! helm template byoc-test "./$chart" -f "$out" >/dev/null 2>"$out.helm.err"; then
    echo "FAIL [$label]: helm template failed"
    head -20 "$out.helm.err"
    rm -f "$out" "$out.helm.err"
    FAIL=1
    return
  fi

  if ! helm lint "./$chart" -f "$out" >/dev/null 2>"$out.lint.err"; then
    echo "FAIL [$label]: helm lint failed"
    head -20 "$out.lint.err"
    rm -f "$out" "$out.helm.err" "$out.lint.err"
    FAIL=1
    return
  fi

  echo "OK [$label]: envsubst clean + helm template + helm lint"
  rm -f "$out" "$out.helm.err" "$out.lint.err"
}

for cloud in aws azure gcs; do
  check_template "BYOC region: $cloud" \
    "scripts/${cloud}-setup/values-region.yaml.tmpl" \
    "scripts/${cloud}-setup/.tests/byoc-prompt-set.env" \
    "charts/daytona-region"
done

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "OK: all 3 cloud values templates render and lint clean"
else
  echo "FAILED: one or more cloud templates failed validation"
fi
exit $FAIL
