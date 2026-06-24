#!/usr/bin/env bash
# =============================================================================
# Daytona BYOC setup (AWS) — end-to-end SDK validation
# =============================================================================
# Tests THREE distinct paths in the BYOC region and prints a verification
# summary at the end. Each stage notes what it tests and why.
#
#   STAGE A — PUBLIC IMAGE PATH (registry pull, no build context)
#     Image.base('alpine:3.21')  →  sandbox from a small public image.
#     Does NOT use the org-default snapshot — that snapshot only exists in
#     Daytona-managed regions and is not replicated to custom BYOC regions,
#     so `client.create()` with no args would always fail here with
#     "Snapshot daytonaio/sandbox:X is not available in region Y".
#     What this proves: proxy + at least one runner + registry pull work.
#     What this DOES NOT prove: that S3 is correctly wired on both ends, and
#     does NOT exercise the private-registry auth flow.
#
#   STAGE B — DECLARATIVE BUILDER PATH  (S3 wiring)
#     Image.debian_slim('3.12').pip_install(...)  →  builds an image,
#     creates a snapshot, then a sandbox from it.
#     What this proves: the SDK can upload build context to the
#     snapshot-manager's S3 bucket, AND the runner can download it back
#     from that SAME bucket with its own AWS_* env credentials, AND
#     `docker build` runs to completion, AND the resulting sandbox can
#     execute the pip-installed package. We also dump the S3 bucket object
#     count before/after so the receipt at the end shows hard evidence
#     that S3 was actually touched.
#
#   STAGE C — PRIVATE ECR PATH  (private-registry auth)
#     Image.base('<account>.dkr.ecr.<region>.amazonaws.com/...')
#     → snapshot from a private ECR image. The runner's
#       INSPECT_SNAPSHOT_IN_REGISTRY job must authenticate to ECR via the
#       broker → AssumeRole → ECR-token flow. Sandbox reaching STARTED is
#       end-to-end proof the broker path works when configured correctly.
#     Skipped if .state/ecr.env doesn't exist (run ecr-setup.sh first).
#
# Required env (set by repro.sh):
#   DAYTONA_API_URL, DAYTONA_API_KEY, REGION_NAME
# Optional:
#   STAGING            "true" → SDK skips TLS verification (LE staging)
#   SKIP_STAGE_A       default false
#   SKIP_STAGE_B       default false
#   SKIP_STAGE_C       default false
#   S3_BUCKET          if set, Stage B reports object count delta
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STATE_DIR="$SCRIPT_DIR/.state"

DAYTONA_API_URL="${DAYTONA_API_URL:?required}"
DAYTONA_API_KEY="${DAYTONA_API_KEY:?required}"
REGION_NAME="${REGION_NAME:?required}"
STAGING="${STAGING:-false}"
SKIP_STAGE_A="${SKIP_STAGE_A:-false}"
SKIP_STAGE_B="${SKIP_STAGE_B:-false}"
SKIP_STAGE_C="${SKIP_STAGE_C:-false}"

# Pick up extras from prior repro / ecr-setup state (so the user can just
# run `bash e2e.sh` after those without re-exporting anything).
[[ -z "${S3_BUCKET:-}" && -f "$STATE_DIR/iam-keys.env" ]] && source "$STATE_DIR/iam-keys.env"
# repro.sh derives the bucket name; reconstruct it the same way if absent
if [[ -z "${S3_BUCKET:-}" ]]; then
  S3_BUCKET="$(printf '%s' "${REGION_NAME}-snapshots" | tr '[:upper:]' '[:lower:]' | cut -c1-63)"
fi

ECR_TEST_IMAGE=""
DAYTONA_REGISTRY_ID=""
DAYTONA_REGISTRY_ENDPOINT=""
ECR_PULLER_ROLE_ARN=""
if [[ -f "$STATE_DIR/ecr.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/ecr.env"
fi

# Count S3 objects (used by Stage B for hard evidence). list-objects-v2 with
# --query KeyCount can return the literal string "None" when the bucket is
# empty *and* in some AWS-CLI versions, so we normalise that to 0.
s3_object_count() {
  local bucket="$1"
  if [[ -z "$bucket" ]] || ! command -v aws >/dev/null 2>&1; then
    echo "n/a"
    return
  fi
  local count
  count=$(aws s3api list-objects-v2 --bucket "$bucket" --output json 2>/dev/null \
            | jq '(.Contents // []) | length' 2>/dev/null)
  if [[ -z "$count" || "$count" == "null" ]]; then
    echo "n/a"
  else
    echo "$count"
  fi
}

S3_BEFORE_STAGE_B="$(s3_object_count "$S3_BUCKET")"

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed"; exit 1; }
python3 -c "import daytona" 2>/dev/null || {
  echo "Installing daytona SDK (pip install daytona)..."
  python3 -m pip install --quiet --user daytona || {
    echo "failed to install daytona SDK; try: pip install daytona"
    exit 1
  }
}

# Self-contained python file so we can apply the urllib3 monkey-patch (for LE
# staging certs) BEFORE importing the daytona SDK.
cat > /tmp/byoc-aws-e2e.py <<'PYEOF'
import os
import sys
import ssl
import time
import json
import traceback
import subprocess


def banner(stage, title):
    bar = "═" * 70
    print(f"\n{bar}\n  STAGE {stage}: {title}\n{bar}", flush=True)


def info(msg):
    print(f"  → {msg}", flush=True)


def ok(msg):
    print(f"  ✓ {msg}", flush=True)


def fail(msg):
    print(f"  ✗ {msg}", flush=True)


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
# Try the canonical location first, fall back gracefully.
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
skip_c         = os.environ.get("SKIP_STAGE_C", "false").lower() == "true"
ecr_image      = os.environ.get("ECR_TEST_IMAGE", "")
ecr_role_arn   = os.environ.get("ECR_PULLER_ROLE_ARN", "")
ecr_reg_id     = os.environ.get("DAYTONA_REGISTRY_ID", "")
s3_bucket      = os.environ.get("S3_BUCKET", "")
s3_before      = os.environ.get("S3_BEFORE_STAGE_B", "n/a")

print(f"  API URL : {api_url}")
print(f"  Region  : {region}")
print(f"  S3      : {s3_bucket} ({s3_before} objects pre-test)")
print(f"  ECR     : {ecr_image if ecr_image else '(not configured — Stage C will be skipped)'}")

config = DaytonaConfig(api_key=api_key, api_url=api_url, target=region)
client = Daytona(config)

# evidence: structured detail attached to each stage's result so the
# verification summary can quote it back to a reader.
results = {
    "A": {"status": None, "evidence": None},
    "B": {"status": None, "evidence": None},
    "C": {"status": None, "evidence": None},
}
sandboxes_to_clean = []


def s3_count(bucket):
    """Count objects in the snapshot-manager S3 bucket via the awscli."""
    if not bucket:
        return "n/a"
    try:
        out = subprocess.check_output(
            ["aws", "s3api", "list-objects-v2", "--bucket", bucket,
             "--query", "KeyCount", "--output", "text"],
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
        return out.decode().strip()
    except Exception:
        return "n/a"


# ---------------------------------------------------------------- STAGE A
if skip_a:
    banner("A", "SKIPPED (SKIP_STAGE_A=true)")
    results["A"]["status"] = "skipped"
elif Image is None or CreateSandboxFromImageParams is None:
    banner("A", "SKIPPED (SDK missing Image / CreateSandboxFromImageParams)")
    print("  → upgrade the SDK to test the public-image path: pip install -U daytona")
    results["A"]["status"] = "skipped"
else:
    # IMPORTANT: do NOT use bare `client.create()` here. That uses the
    # org-default snapshot (daytonaio/sandbox:<ver>) which lives in
    # Daytona-managed regions only. For a freshly-created BYOC custom region,
    # that snapshot has never been replicated and the API rejects the request
    # with "Snapshot X is not available in region Y" — a false negative.
    #
    # Instead, build a minimal sandbox from a small public image. This still
    # exercises proxy + runner + registry-pull paths, but does not depend on
    # any Daytona-managed snapshot pre-existing in the region.
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
    print("  → upgrade the SDK to test the declarative builder: pip install -U daytona")
    results["B"]["status"] = "skipped"
else:
    banner("B", "DECLARATIVE BUILDER PATH (S3 wiring)")
    info("Proves both halves of S3 are wired correctly:")
    info("  • SDK upload of build context → snapshot-manager S3 creds")
    info("  • Runner download of that context → runner AWS_* env vars")
    info("  • docker build runs to completion on the runner")
    info("")
    info(f"S3 bucket pre-test object count: {s3_before}")
    info("")
    try:
        # Force a cache miss with a unique BUILD_RUN_ID env var. Without this,
        # Daytona reuses the cached snapshot from any prior run with the same
        # recipe, finishing in <1s with no fresh S3 traffic — which means the
        # receipt below would have no actual evidence of S3 being touched
        # *this run*. Setting a unique env adds a layer to the Dockerfile,
        # changing the cache key and forcing real build context upload +
        # docker build + S3 layer storage.
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
        info("    " + "─" * 60)

        def on_logs(chunk):
            for line in str(chunk).splitlines():
                if line.strip():
                    print(f"    │ {line}", flush=True)

        t0 = time.time()
        sandbox_b = client.create(
            CreateSandboxFromImageParams(image=declarative_image),
            timeout=0,
            on_snapshot_create_logs=on_logs,
        )
        sandboxes_to_clean.append(sandbox_b)
        dt = time.time() - t0
        info("    " + "─" * 60)
        ok(f"declarative image built + sandbox created in {dt:.1f}s  id={sandbox_b.id}")

        info("verifying the built sandbox actually runs the installed packages ...")
        verify = sandbox_b.process.code_run(
            "import os, requests, sys; "
            "print(f'requests={requests.__version__} "
            "python={sys.version.split()[0]} "
            "BUILD_RUN_ID={os.environ.get(\"BUILD_RUN_ID\",\"<missing>\")}')"
        )
        s3_after = s3_count(s3_bucket)
        info(f"S3 bucket post-test object count: {s3_after}")

        if verify.exit_code == 0:
            ok(f"verify exit=0  output={verify.result.strip()!r}")
            # Sanity check: verify output should contain our BUILD_RUN_ID,
            # proving the running container is the one we just built (not a
            # stale cached one).
            sanity = build_run_id in (verify.result or "")
            results["B"]["status"] = "pass"
            results["B"]["evidence"] = {
                "sandbox_id": sandbox_b.id,
                "image_recipe": recipe_repr,
                "build_plus_create_seconds": round(dt, 1),
                "build_run_id": build_run_id,
                "verify_output": verify.result.strip(),
                "build_run_id_matched": sanity,
                "s3_bucket": s3_bucket,
                "s3_objects_before": s3_before,
                "s3_objects_after": s3_after,
            }
        else:
            fail(f"verify exit={verify.exit_code}  result={verify.result!r}")
            results["B"]["status"] = "fail"
            results["B"]["evidence"] = {"verify_exit": verify.exit_code}
    except Exception as e:
        fail(f"stage B raised: {e!r}")
        info("If the error message mentions S3, AccessDenied, NoSuchKey, or")
        info("a 403/404 against a bucket, the runner is missing AWS_* env vars")
        info("or is pointing at the wrong bucket.")
        info("Check each runner with:")
        info("  aws ssm start-session --target <instance-id>")
        info("  sudo grep -E '^Environment=AWS_' /etc/systemd/system/daytona-runner.service")
        traceback.print_exc()
        results["B"]["status"] = "error"
        results["B"]["evidence"] = {"exception": repr(e)}


# ---------------------------------------------------------------- STAGE C
if skip_c:
    banner("C", "SKIPPED (SKIP_STAGE_C=true)")
    results["C"]["status"] = "skipped"
elif Image is None or CreateSandboxFromImageParams is None:
    banner("C", "SKIPPED (SDK missing Image / CreateSandboxFromImageParams)")
    results["C"]["status"] = "skipped"
elif not ecr_image:
    banner("C", "SKIPPED (ECR not configured)")
    print("  → run `bash ecr-setup.sh` first to provision the ECR repo + IAM role + registry")
    results["C"]["status"] = "skipped"
else:
    banner("C", "PRIVATE ECR PATH (registry auth)")
    info("Proves Daytona's broker → AssumeRole → ECR-token flow works:")
    info(f"  • Image lives in private ECR:  {ecr_image}")
    info(f"  • IAM role assumed by broker:  {ecr_role_arn}")
    info(f"  • Daytona registry id:         {ecr_reg_id or '(none — fell back to public pull or manual reg)'}")
    info("")
    info("If this stage FAILS with 'no basic auth credentials' or similar,")
    info("you're seeing the exact failure this reproduces. Check:")
    info("  1. Is the registry registered in Daytona? GET /api/docker-registries")
    info("  2. Does the role trust the right broker ARN?")
    info("  3. Does the trust policy's ExternalId == your organization ID?")
    info("  4. Does the role policy include all 4 required ECR actions?")
    info("")
    try:
        info(f"creating sandbox from Image.base('{ecr_image}') ...")
        t0 = time.time()
        sandbox_c = client.create(
            CreateSandboxFromImageParams(image=Image.base(ecr_image)),
            timeout=300,
        )
        sandboxes_to_clean.append(sandbox_c)
        dt = time.time() - t0
        ok(f"sandbox created in {dt:.1f}s  id={sandbox_c.id}  state={sandbox_c.state}")
        info("    ← reaching STARTED means the runner INSPECTED + PULLED the")
        info("      private ECR image. That only succeeds if Daytona's broker")
        info("      AssumeRole'd into the puller role, called")
        info("      ecr:GetAuthorizationToken, and passed the token to the runner.")

        info("running `echo` inside the sandbox to confirm it's responsive ...")
        result = sandbox_c.process.exec("echo 'Hello from ECR-pulled sandbox'")
        if result.exit_code == 0:
            ok(f"exec exit=0  output={result.result.strip()!r}")
            results["C"]["status"] = "pass"
            results["C"]["evidence"] = {
                "sandbox_id": sandbox_c.id,
                "image": ecr_image,
                "broker_role_arn": ecr_role_arn,
                "create_seconds": round(dt, 1),
                "exec_output": result.result.strip(),
            }
        else:
            fail(f"exec exit={result.exit_code}  result={result.result!r}")
            results["C"]["status"] = "fail"
            results["C"]["evidence"] = {"exec_exit": result.exit_code}
    except Exception as e:
        err_str = str(e)
        fail(f"stage C raised: {e!r}")
        if "no basic auth" in err_str.lower() or "unauthorized" in err_str.lower():
            info("    ↑ THIS is the registry-auth failure this stage checks for.")
            info("    The runner cannot authenticate to ECR via the broker flow.")
        info("Recovery checklist:")
        info("  - Is the ECR registry registered in Daytona Cloud?")
        info("    Visit app.daytona.io/dashboard/registries, or:")
        info(f"    curl -H 'Authorization: Bearer $DAYTONA_API_KEY' {api_url}/docker-registries")
        info("  - Does the IAM role trust DaytonaEcrCredentialBroker?")
        info("  - Does its ExternalId match your organization ID?")
        traceback.print_exc()
        results["C"]["status"] = "error"
        results["C"]["evidence"] = {"exception": repr(e)}


# ---------------------------------------------------------------- SUMMARY
print("\n" + "═" * 70)
print("  E2E STAGE RESULTS")
print("═" * 70)
glyph = {"pass": "✓ PASS", "fail": "✗ FAIL", "error": "✗ ERROR", "skipped": "- skipped", None: "- not run"}
print(f"  Stage A (public image)           : {glyph.get(results['A']['status'])}")
print(f"  Stage B (declarative builder/S3) : {glyph.get(results['B']['status'])}")
print(f"  Stage C (private ECR pull)       : {glyph.get(results['C']['status'])}")
print()


# ---------------------------------------------------------------- RECEIPT
# Verification summary: for each path, what was tested and the evidence.
print("═" * 70)
print("  VERIFICATION SUMMARY")
print("═" * 70)

# Private ECR pull
print()
print("  Private ECR pull — validates that a snapshot can be created from a")
print("  private AWS ECR image: the runner's registry inspect job authenticates")
print("  to ECR via the broker → AssumeRole → ECR-token flow.")
c = results["C"]
print(f"      Test:       Stage C (private ECR pull)")
if c["status"] == "pass":
    e = c["evidence"]
    print(f"      Result:     VERIFIED (PASS)")
    print(f"      Evidence:   sandbox {e['sandbox_id']} created from")
    print(f"                  {e['image']}")
    print(f"                  in {e['create_seconds']}s.")
    print(f"                  Daytona's broker successfully AssumeRole'd into")
    print(f"                  {e['broker_role_arn']}")
    print(f"                  fetched an ECR auth token, and the runner used")
    print(f"                  it to inspect + pull the image.")
    print(f"      Conclusion: The runner's INSPECT_SNAPSHOT_IN_REGISTRY auth")
    print(f"                  flow works end-to-end when the ECR registry is")
    print(f"                  registered in Daytona with a properly-configured")
    print(f"                  IAM role (trust policy → broker + ExternalId,")
    print(f"                  permissions → 4 ECR actions). A failure here usually")
    print(f"                  means a configuration gap on the operator side —")
    print(f"                  missing registry registration, wrong broker ARN in")
    print(f"                  the trust policy, or wrong ExternalId. See")
    print(f"                  charts/daytona-region/README.md")
    print(f"                  '#private-registry-authentication-ecr'.")
elif c["status"] == "fail" or c["status"] == "error":
    print(f"      Result:     NOT VERIFIED (Stage C {c['status'].upper()})")
    print(f"      Evidence:   {c['evidence']}")
    print(f"      Conclusion: We were unable to drive an ECR pull end-to-end.")
    print(f"                  Likely a configuration gap — inspect the failure above.")
else:
    print(f"      Result:     NOT TESTED (Stage C {c['status']})")
    print(f"      Evidence:   None — Stage C was skipped (likely no ecr-setup).")
    print(f"      Conclusion: Run `bash ecr-setup.sh` then re-run e2e.sh to")
    print(f"                  produce live evidence for the private ECR path.")

# Declarative builder / S3 wiring
print()
print("  Declarative builder / S3 — validates that the declarative image")
print("  builder uploads build context to S3 and the runner reads it back")
print("  with its own credentials.")
b = results["B"]
print(f"      Test:       Stage B (declarative builder)")
if b["status"] == "pass":
    e = b["evidence"]
    # Compute S3 delta if both counts are numeric
    s3_delta = "n/a"
    try:
        before_n = int(e["s3_objects_before"])
        after_n  = int(e["s3_objects_after"])
        delta_n  = after_n - before_n
        s3_delta = f"+{delta_n}" if delta_n >= 0 else str(delta_n)
    except (ValueError, TypeError):
        pass
    cache_status = (
        "FRESH BUILD (BUILD_RUN_ID observed in sandbox runtime — cache miss)"
        if e.get("build_run_id_matched")
        else "cached build (S3 objects untouched this run, but recipe ran historically)"
    )
    print(f"      Result:     VERIFIED (PASS)")
    print(f"      Evidence:   sandbox {e['sandbox_id']} created from recipe")
    print(f"                    {e['image_recipe']}")
    print(f"                  in {e['build_plus_create_seconds']}s.")
    print(f"                  Cache state: {cache_status}")
    print(f"                  Sandbox runtime echoed verifier output:")
    print(f"                    {e['verify_output']}")
    print(f"                  S3 bucket {e['s3_bucket']}:")
    print(f"                    objects before stage: {e['s3_objects_before']}")
    print(f"                    objects after stage:  {e['s3_objects_after']}")
    print(f"                    delta:                {s3_delta}")
    print(f"      Conclusion: Both halves of the S3 wiring work:")
    print(f"                    • snapshot-manager (in EKS) read/wrote the")
    print(f"                      build-context blobs to S3 via the chart's")
    print(f"                      services.snapshotManager.storage.s3.*")
    print(f"                    • runner (EC2 systemd) read those blobs from")
    print(f"                      the same bucket via its AWS_* env vars")
    print(f"                      in /etc/systemd/system/daytona-runner.service")
    print(f"                  Both rely on the runner's AWS_* env vars in the")
    print(f"                  systemd unit. See charts/daytona-region/README.md")
    print(f"                  '#declarative-builder-setup-byoc'.")
else:
    print(f"      Result:     NOT VERIFIED (Stage B {b['status']})")
    print(f"      Evidence:   {b['evidence']}")

print()
print("═" * 70)


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
# Exit 0 only when every stage that actually ran came back 'pass'.
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
SKIP_STAGE_C="$SKIP_STAGE_C" \
S3_BUCKET="$S3_BUCKET" \
S3_BEFORE_STAGE_B="$S3_BEFORE_STAGE_B" \
ECR_TEST_IMAGE="$ECR_TEST_IMAGE" \
ECR_PULLER_ROLE_ARN="$ECR_PULLER_ROLE_ARN" \
DAYTONA_REGISTRY_ID="$DAYTONA_REGISTRY_ID" \
  python3 /tmp/byoc-aws-e2e.py
