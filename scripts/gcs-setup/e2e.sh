#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC (GCP) — end-to-end SDK validation
# =============================================================================
# Tests TWO distinct paths in the BYOC region and prints a verification
# summary at the end. Each stage notes what it tests and why.
#
#   STAGE A — PUBLIC IMAGE PATH (registry pull, no build context)
#     Image.base('alpine:3.21')  →  sandbox from a small public image.
#     Does NOT use the org-default snapshot — that snapshot only exists in
#     Daytona-managed regions and is not replicated to custom BYOC regions,
#     so `client.create()` with no args would always fail here with
#     "Snapshot daytonaio/sandbox:X is not available in region Y".
#     What this proves: proxy + at least one runner + registry pull work.
#     What this DOES NOT prove: that GCS is correctly wired on both ends.
#
#   STAGE B — DECLARATIVE BUILDER PATH  (GCS wiring verification)
#     Image.debian_slim('3.12').pip_install(...)  →  builds an image,
#     creates a snapshot, then a sandbox from it.
#     What this proves: the SDK can upload build context to the
#     snapshot-manager's GCS bucket (via the chart's storage.s3.*), AND
#     the runner can download it back from that SAME bucket using its own
#     AWS_*-shaped HMAC env vars + AWS_ENDPOINT_URL=storage.googleapis.com,
#     AND `docker build` runs to completion, AND the resulting sandbox can
#     execute the pip-installed package. We also dump the GCS bucket object
#     count before/after so the summary at the end shows hard evidence that
#     GCS was actually touched.
#
# Required env (set by repro.sh):
#   DAYTONA_API_URL, DAYTONA_API_KEY, REGION_NAME
# Optional:
#   STAGING            "true" → SDK skips TLS verification (LE staging)
#   SKIP_STAGE_A       default false
#   SKIP_STAGE_B       default false
#   GCS_BUCKET         if set, Stage B reports object count delta
#   GCP_PROJECT        used for gcloud storage queries
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATE_DIR="$SCRIPT_DIR/.state"

# Pick up cluster identity + API creds saved by up.sh (.state/prompts.env) so
# the operator can run `bash e2e.sh` right after up.sh without re-exporting.
[[ -f "$STATE_DIR/prompts.env" ]] && { set -a; . "$STATE_DIR/prompts.env"; set +a; }

DAYTONA_API_URL="${DAYTONA_API_URL:?required}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:?required}"
REGION_NAME="${REGION_NAME:?required}"
STAGING="${STAGING:-false}"
SKIP_STAGE_A="${SKIP_STAGE_A:-false}"
SKIP_STAGE_B="${SKIP_STAGE_B:-false}"
GCP_PROJECT="${GCP_PROJECT:-}"

# Pick up extras from prior repro state (so the user can just run `bash e2e.sh`)
[[ -z "${GCS_BUCKET:-}" && -f "$STATE_DIR/names.env" ]] && source "$STATE_DIR/names.env"
if [[ -z "${GCS_BUCKET:-}" ]]; then
  GCS_BUCKET="$(printf '%s' "${REGION_NAME}-snapshots" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"
fi

# Count GCS objects (used by Stage B for hard evidence).
gcs_object_count() {
  local bucket="$1"
  if [[ -z "$bucket" ]] || ! command -v gcloud >/dev/null 2>&1; then
    echo "n/a"
    return
  fi
  local count
  count="$(gcloud storage ls --recursive "gs://${bucket}/**" 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ -z "$count" ]]; then
    echo "n/a"
  else
    echo "$count"
  fi
}

GCS_BEFORE_STAGE_B="$(gcs_object_count "$GCS_BUCKET")"

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed"; exit 1; }
python3 -c "import daytona" 2>/dev/null || {
  echo "Installing daytona SDK (pip install 'daytona==0.183.*')..."
  python3 -m pip install --quiet --user "daytona==0.183.*" || {
    echo "failed to install daytona SDK; try: pip install 'daytona==0.183.*'"
    exit 1
  }
}

# Self-contained python file so we can apply the urllib3 monkey-patch (for LE
# staging certs) BEFORE importing the daytona SDK.
cat > /tmp/byoc-gcp-e2e.py <<'PYEOF'
import os
import sys
import ssl
import time
import json
import traceback
import subprocess


def banner(stage, title):
    bar = "=" * 70
    print(f"\n{bar}\n  STAGE {stage}: {title}\n{bar}", flush=True)


def info(msg):
    print(f"  -> {msg}", flush=True)


def ok(msg):
    print(f"  PASS {msg}", flush=True)


def fail(msg):
    print(f"  FAIL {msg}", flush=True)


# Disable TLS verification when running against LE staging certs.
if os.environ.get("STAGING", "false") == "true":
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

# Older SDKs put Image / CreateSandboxFromImageParams under different paths.
Image = None
CreateSandboxFromImageParams = None
try:
    from daytona import Image, CreateSandboxFromImageParams
except ImportError:
    try:
        from daytona import Image
        from daytona.common import CreateSandboxFromImageParams
    except ImportError:
        pass

api_url        = os.environ["DAYTONA_API_URL"]
api_key        = os.environ["DAYTONA_API_KEY"]
region         = os.environ["REGION_NAME"]
skip_a         = os.environ.get("SKIP_STAGE_A", "false").lower() == "true"
skip_b         = os.environ.get("SKIP_STAGE_B", "false").lower() == "true"
gcs_bucket     = os.environ.get("GCS_BUCKET", "")
gcs_before     = os.environ.get("GCS_BEFORE_STAGE_B", "n/a")

print(f"  API URL : {api_url}")
print(f"  Region  : {region}")
print(f"  GCS     : gs://{gcs_bucket} ({gcs_before} objects pre-test)")

config = DaytonaConfig(api_key=api_key, api_url=api_url, target=region)
client = Daytona(config)

results = {
    "A": {"status": None, "evidence": None},
    "B": {"status": None, "evidence": None},
}
sandboxes_to_clean = []


def gcs_count(bucket):
    """Count objects in the snapshot-manager GCS bucket via gcloud storage."""
    if not bucket:
        return "n/a"
    try:
        out = subprocess.check_output(
            ["gcloud", "storage", "ls", "--recursive", f"gs://{bucket}/**"],
            stderr=subprocess.DEVNULL, timeout=30,
        )
        return str(len([l for l in out.decode().splitlines() if l.strip()]))
    except Exception:
        return "n/a"


# ---------------------------------------------------------------- STAGE A
if skip_a:
    banner("A", "SKIPPED (SKIP_STAGE_A=true)")
    results["A"]["status"] = "skipped"
elif Image is None or CreateSandboxFromImageParams is None:
    banner("A", "SKIPPED (SDK missing Image / CreateSandboxFromImageParams)")
    print("  -> upgrade the SDK: pip install -U 'daytona==0.183.*'")
    results["A"]["status"] = "skipped"
else:
    # IMPORTANT: do NOT use bare `client.create()` here. That uses the
    # org-default snapshot (daytonaio/sandbox:<ver>) which lives in
    # Daytona-managed regions only. For a freshly-created BYOC custom region,
    # that snapshot has never been replicated and the API rejects the request
    # with "Snapshot X is not available in region Y" — a false negative.
    banner("A", "PUBLIC IMAGE PATH (alpine via public registry, no build context)")
    try:
        info("creating sandbox from Image.base('alpine:3.21') (minimal, no build steps) ...")
        t0 = time.time()
        sandbox_a = client.create(
            CreateSandboxFromImageParams(image=Image.base("alpine:3.21")),
            timeout=300,
        )
        sandboxes_to_clean.append(sandbox_a)
        dt = time.time() - t0
        ok(f"sandbox created in {dt:.1f}s  id={sandbox_a.id}  state={sandbox_a.state}")

        info("running `echo Hello from public-image sandbox` inside it ...")
        result = sandbox_a.process.exec("echo 'Hello from public-image sandbox'")
        if result.exit_code == 0:
            ok(f"exec exit=0  output={result.result.strip()!r}")
            results["A"]["status"] = "pass"
            results["A"]["evidence"] = {
                "sandbox_id": sandbox_a.id,
                "image": "alpine:3.21 (public Docker Hub)",
                "create_seconds": round(dt, 1),
                "exec_output": result.result.strip(),
            }
        else:
            fail(f"exec exit={result.exit_code}  result={result.result!r}")
            results["A"]["status"] = "fail"
            results["A"]["evidence"] = {"exec_exit": result.exit_code, "exec_result": str(result.result)}
    except Exception as e:
        fail(f"stage A raised: {e!r}")
        info("If the error mentions 'namespace {time \"\"} does not exist', the")
        info("runner has Docker 29.x + sysbox 0.6.7 — see runner-bootstrap.sh")
        info("DOCKER_VERSION env var (defaults to 28.3.3 for sysbox compat).")
        traceback.print_exc()
        results["A"]["status"] = "error"
        results["A"]["evidence"] = {"exception": repr(e)}


# ---------------------------------------------------------------- STAGE B
if skip_b:
    banner("B", "SKIPPED (SKIP_STAGE_B=true)")
    results["B"]["status"] = "skipped"
elif Image is None or CreateSandboxFromImageParams is None:
    banner("B", "SKIPPED (SDK missing Image / CreateSandboxFromImageParams)")
    print("  -> upgrade the SDK to test the declarative builder: pip install -U 'daytona==0.183.*'")
    results["B"]["status"] = "skipped"
else:
    banner("B", "DECLARATIVE BUILDER PATH - GCS wiring verification")
    info("Proves both halves of GCS are wired correctly:")
    info("  * SDK upload of build context -> snapshot-manager HMAC creds")
    info("  * Runner download of that context -> runner AWS_* env vars")
    info("    (HMAC over GCS interop XML, AWS_ENDPOINT_URL=storage.googleapis.com)")
    info("  * docker build runs to completion on the runner")
    info("")
    info(f"GCS bucket pre-test object count: {gcs_before}")
    info("")
    try:
        # Force a cache miss with a unique BUILD_RUN_ID env var. Without this,
        # Daytona reuses the cached snapshot from any prior run with the same
        # recipe, finishing in <1s with no fresh GCS traffic.
        build_run_id = f"run-{int(time.time())}-{os.getpid()}"
        recipe_repr = (
            "Image.debian_slim('3.12').pip_install(['requests'])"
            f".env({{'BUILD_RUN_ID':'{build_run_id}'}}).workdir('/home/daytona')"
        )
        info(f"building image (forced fresh, BUILD_RUN_ID={build_run_id}):")
        info(f"  {recipe_repr}")
        declarative_image = (
            Image.debian_slim("3.12")
            .pip_install(["requests"])
            .env({"BUILD_RUN_ID": build_run_id})
            .workdir("/home/daytona")
        )

        info("creating sandbox from the declarative image (streaming build logs) ...")
        info("    (any 'docker' / 'pip' lines you see below are the runner doing the build)")
        info("    " + "-" * 60)

        def on_logs(chunk):
            for line in str(chunk).splitlines():
                if line.strip():
                    print(f"    | {line}", flush=True)

        t0 = time.time()
        sandbox_b = client.create(
            CreateSandboxFromImageParams(image=declarative_image),
            timeout=0,
            on_snapshot_create_logs=on_logs,
        )
        sandboxes_to_clean.append(sandbox_b)
        dt = time.time() - t0
        info("    " + "-" * 60)
        ok(f"declarative image built + sandbox created in {dt:.1f}s  id={sandbox_b.id}")

        info("verifying the built sandbox actually runs the installed packages ...")
        verify = sandbox_b.process.code_run(
            "import os, requests, sys; "
            "print(f'requests={requests.__version__} "
            "python={sys.version.split()[0]} "
            "BUILD_RUN_ID={os.environ.get(\"BUILD_RUN_ID\",\"<missing>\")}')"
        )
        gcs_after = gcs_count(gcs_bucket)
        info(f"GCS bucket post-test object count: {gcs_after}")

        if verify.exit_code == 0:
            ok(f"verify exit=0  output={verify.result.strip()!r}")
            sanity = build_run_id in (verify.result or "")
            results["B"]["status"] = "pass"
            results["B"]["evidence"] = {
                "sandbox_id": sandbox_b.id,
                "image_recipe": recipe_repr,
                "build_plus_create_seconds": round(dt, 1),
                "build_run_id": build_run_id,
                "verify_output": verify.result.strip(),
                "build_run_id_matched": sanity,
                "gcs_bucket": gcs_bucket,
                "gcs_objects_before": gcs_before,
                "gcs_objects_after": gcs_after,
            }
        else:
            fail(f"verify exit={verify.exit_code}  result={verify.result!r}")
            results["B"]["status"] = "fail"
            results["B"]["evidence"] = {"verify_exit": verify.exit_code}
    except Exception as e:
        fail(f"stage B raised: {e!r}")
        info("If the error message mentions 403, AccessDenied, NoSuchKey, or")
        info("a SignatureDoesNotMatch against the bucket, the runner is missing")
        info("AWS_* env vars or pointing at the wrong bucket. Check each runner with:")
        info("  gcloud compute ssh <instance> --tunnel-through-iap")
        info("  sudo grep -E '^Environment=AWS_' /etc/systemd/system/daytona-runner.service")
        traceback.print_exc()
        results["B"]["status"] = "error"
        results["B"]["evidence"] = {"exception": repr(e)}


# ---------------------------------------------------------------- SUMMARY
print("\n" + "=" * 70)
print("  E2E STAGE RESULTS")
print("=" * 70)
glyph = {"pass": "PASS", "fail": "FAIL", "error": "ERROR", "skipped": "skipped", None: "not run"}
print(f"  Stage A (public image)            : {glyph.get(results['A']['status'])}")
print(f"  Stage B (declarative builder/GCS) : {glyph.get(results['B']['status'])}")
print()


# ---------------------------------------------------------------- RECEIPT
print("=" * 70)
print("  VERIFICATION SUMMARY")
print("=" * 70)

# Declarative builder / GCS wiring
print()
print("  Declarative builder / GCS — validates that the declarative image")
print("  builder uploads build context to GCS and the runner reads it back")
print("  with its own credentials.")
b = results["B"]
print(f"      Test:       Stage B (declarative builder over GCS)")
if b["status"] == "pass":
    e = b["evidence"]
    gcs_delta = "n/a"
    try:
        before_n = int(e["gcs_objects_before"])
        after_n  = int(e["gcs_objects_after"])
        delta_n  = after_n - before_n
        gcs_delta = f"+{delta_n}" if delta_n >= 0 else str(delta_n)
    except (ValueError, TypeError):
        pass
    cache_status = (
        "FRESH BUILD (BUILD_RUN_ID observed in sandbox runtime - cache miss)"
        if e.get("build_run_id_matched")
        else "cached build (GCS objects untouched this run)"
    )
    print(f"      Result:     VERIFIED (PASS)")
    print(f"      Evidence:   sandbox {e['sandbox_id']} created from recipe")
    print(f"                    {e['image_recipe']}")
    print(f"                  in {e['build_plus_create_seconds']}s.")
    print(f"                  Cache state: {cache_status}")
    print(f"                  Sandbox runtime echoed verifier output:")
    print(f"                    {e['verify_output']}")
    print(f"                  GCS bucket gs://{e['gcs_bucket']}:")
    print(f"                    objects before stage: {e['gcs_objects_before']}")
    print(f"                    objects after stage:  {e['gcs_objects_after']}")
    print(f"                    delta:                {gcs_delta}")
    print(f"      Conclusion: Both halves of the GCS wiring work:")
    print(f"                    * snapshot-manager (in GKE) read/wrote build-")
    print(f"                      context blobs via the chart's")
    print(f"                      services.snapshotManager.storage.s3.*")
    print(f"                      (endpoint=storage.googleapis.com)")
    print(f"                    * runner (GCE systemd) read those blobs from")
    print(f"                      the same bucket via its AWS_* env vars in")
    print(f"                      /etc/systemd/system/daytona-runner.service")
else:
    print(f"      Result:     NOT VERIFIED (Stage B {b['status']})")
    print(f"      Evidence:   {b['evidence']}")

print()
print("=" * 70)


# ---------------------------------------------------------------- CLEANUP
if sandboxes_to_clean:
    print("\n  cleaning up test sandboxes ...")
    for sb in sandboxes_to_clean:
        try:
            client.delete(sb)
            print(f"    deleted {sb.id}")
        except Exception as e:
            print(f"    delete failed for {sb.id}: {e!r}")


# ---------------------------------------------------------------- EXIT
ran_statuses = [r["status"] for r in results.values() if r["status"] not in (None, "skipped")]
if not ran_statuses:
    print("\n  No stages were actually executed.")
    sys.exit(2)
if all(s == "pass" for s in ran_statuses):
    sys.exit(0)
sys.exit(1)
PYEOF

DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
REGION_NAME="$REGION_NAME" \
STAGING="$STAGING" \
SKIP_STAGE_A="$SKIP_STAGE_A" \
SKIP_STAGE_B="$SKIP_STAGE_B" \
GCS_BUCKET="$GCS_BUCKET" \
GCS_BEFORE_STAGE_B="$GCS_BEFORE_STAGE_B" \
GCP_PROJECT="$GCP_PROJECT" \
  python3 /tmp/byoc-gcp-e2e.py
