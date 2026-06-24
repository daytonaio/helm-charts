# Daytona BYOC — GCP / GKE Standard

Single interactive script that creates a GKE **Standard** cluster (NOT Autopilot), a GCS bucket with HMAC keys for S3-interop (runner backup storage), and deploys the daytona-region helm chart — including SSH gateway keys and the post-registration region-scoped gateway key swap.

## Prerequisites

| Tool | Check |
|---|---|
| `gcloud` 568+ | `gcloud --version` |
| `kubectl`, `helm`, `envsubst`, `yq`, `jq` | see [`README.md`](README.md) |

GCP project:

```bash
gcloud auth login
gcloud auth application-default login    # ADC for storage HMAC create
gcloud config set project <your-project>
gcloud projects describe <your-project>  # confirm
```

Required roles on the project: `roles/container.admin`, `roles/storage.admin`,
and `roles/iam.serviceAccountAdmin`. Artifact Registry permissions are needed
only if you run the optional registry helper outside the main `up.sh` flow.

## Run

```bash
cd <helm-charts repo root>
bash scripts/gcs-setup/up.sh
```

Prompts:

| Prompt | Default | Notes |
|---|---|---|
| Cluster name | `daytona-byoc-<timestamp>` | |
| Public base DNS domain | — | |
| Daytona region name | `<cluster>` | |
| Email for Let's Encrypt | — | |
| Daytona Cloud API URL | `https://app.daytona.io/api` | |
| Daytona Cloud admin API key | — | **secret** |
| GCP project ID | — | no default; must prompt |
| GCP region | `us-central1` | |
| GCS bucket name | `<cluster>-snapshots` | Globally unique |
| Runner image tag | `v0.183.0` | Default matches chart appVersion |

The script selects a GKE machine type that fits the regional node footprint and
your quota, unless you override it with `OMC_INSTANCE_TYPE`.

## What the script does

1. **GKE Standard cluster** — explicitly NOT Autopilot. Autopilot blocks privileged DaemonSets, and the Daytona runner uses sysbox + `nsenter` into host PID 1 → it MUST be privileged. Created with `--workload-pool=<project>.svc.id.goog` (Workload Identity ready), `--image-type=UBUNTU_CONTAINERD`, stable release channel, and the quota-aware machine type. ~5-10 min. After node pool join, an `omc::verify_node_ubuntu "24.04"` gate refuses to continue if sandbox nodes aren't on Ubuntu 24.04 — no exceptions.
2. **Sandbox node pool** `daytona-sandbox` with `daytona-sandbox-c=true` label + `sandbox=true:NoSchedule` taint, on Ubuntu containerd nodes with the selected machine type.
3. **GCS bucket** + **GSA** (`daytona-byoc-<cluster>@<project>.iam.gserviceaccount.com`) + `roles/storage.objectAdmin` binding on the bucket.
4. **HMAC keys** for the GSA via `gcloud storage hmac create`. The accessId + secret are S3-compatible credentials. Saved 0600 to `.state/hmac.env`.
5. **kubeconfig** via `gcloud container clusters get-credentials`.
6. **daytona namespace** + **PSA privileged label** (`pod-security.kubernetes.io/enforce=privileged`). GKE 1.25+ enforces Pod Security Admission by default; this label is required for the privileged runner DaemonSet.
7. **ingress-nginx** + **cert-manager** + Let's Encrypt ClusterIssuer.
8. **LoadBalancer wait** for the GCP regional LB IP.
9. **DNS records** printed.
10. **SSH gateway keypairs** generated into `.state/`, then **`helm install daytona-region`** with `https://storage.googleapis.com` as the RUNNERS' S3 endpoint (backups + build context via HMAC). The snapshot-manager does NOT use GCS interop — its registry runs on a filesystem PVC (the registry s3 driver needs full multipart-upload semantics; distribution ships a native `gcs` driver for GCS precisely because interop is not sufficient, and the snapshot-manager does not compile it).
11. **Post-registration finalize** (`omc::region_sshgateway_finalize`): fetches the region-scoped ssh-gateway api key, rolls it into the release (`.state/values-sshgateway-key.yaml`), bounces the gateway pod, and PATCHes the region's `sshGatewayUrl` with the gateway LoadBalancer address.

## Verify

```bash
kubectl -n daytona get pods

# PSA label applied?
kubectl get namespace daytona -o yaml | grep pod-security

# HMAC keys reaching the runners? (the DaemonSet is sidecar-only host prep;
# the runner-manager's spawned pods consume this Secret)
kubectl -n daytona get secret daytona-region-runner-secrets \
  -o jsonpath='{.data.AWS_ENDPOINT_URL}' | base64 -d; echo

# Snapshot-manager on its filesystem PVC?
kubectl -n daytona logs deployment/daytona-region-snapshot-manager --tail=5 | grep storage
kubectl -n daytona get pvc daytona-region-snapshot-manager-data
```

You should see `https://storage.googleapis.com` from the runner Secret, and the snapshot-manager reporting `driver:filesystem` with a Bound PVC.

## Smoke test

Same as AWS — open <https://app.daytona.io/dashboard/sandboxes>, create a sandbox in your BYOC region, expect `Ready` within ~60s.

Programmatic:

```bash
export DAYTONA_API_URL=https://app.daytona.io/api
export DAYTONA_API_KEY=<your-key>
export REGION_NAME=<region-name>
bash scripts/gcs-setup/e2e.sh
```

## Teardown

```bash
bash scripts/gcs-setup/teardown.sh
```

1. Helm uninstalls daytona-region
2. Deletes daytona namespace
3. Deactivates + deletes HMAC keys
4. Removes IAM binding + deletes GSA
5. Recursively deletes GCS bucket
6. Deletes GKE cluster (~5-10 min)
7. Cleans up `.state/` and kubeconfig contexts

Confirm with `gcloud container clusters describe <name> --region <region>` → `NOT_FOUND`.

## GKE-specific: sandbox DNS + egress

**DNS is broken-by-default on GKE for sandboxes once you harden egress.**
GKE node `/etc/resolv.conf` points at the GCE metadata resolver
(`169.254.169.254`); sandboxes inherit it through the runner's dockerd, and
the egress policy (`services.runner.networkPolicy`) blocks exactly that IP.
Always set BOTH when enabling the policy on GKE — the docker daemon `dns`
covers sandbox runtime, the buildkitd.toml covers snapshot-build `RUN`
steps (their network namespace does not inherit daemon.json):

```yaml
services:
  runner:
    dockerInstaller:
      dns: ["8.8.8.8", "1.1.1.1"]
    buildkit:
      dns:
        nameservers: ["8.8.8.8", "1.1.1.1"]
    networkPolicy:
      enabled: true       # blocks RFC1918, the GKE service CIDR (10.x), and 169.254.0.0/16
```

The configured resolvers are automatically exempted from the egress block
list. Full background: [`operations.md`](operations.md#sandbox-network-security-and-dns).

## Known gaps

- **GKE Workload Identity for the runner pod** is still pending upstream. Until then, HMAC keys are the S3-compat path (works just like AWS IRSA static keys). Same gap applies to the gcsfuse volume backend (`services.runner.volumes.gcs.credentialsFile` requires a key file — ambient credentials are not forwarded; see [`operations.md`](operations.md#sandbox-volumes)).
- **Artifact Registry (AR)** is NOT created by `up.sh` — the legacy `scripts/gcs-setup/.legacy/gcr-setup.sh` handles AR for the operator's own snapshot images, but it's optional. The daytona-runner does NOT pull from operator-owned registries; the Daytona control plane brokers private registry auth centrally.
- **Wildcard DNS** is not issued (HTTP-01 limitations). See [`troubleshooting.md`](troubleshooting.md) for the DNS-01 upgrade path.

## State files

| File | Mode | Purpose |
|---|---|---|
| `scripts/gcs-setup/.state/prompts.env` | 600 | Prompt answers |
| `scripts/gcs-setup/.state/hmac.env` | 600 | GCS HMAC access ID + secret |
| `scripts/gcs-setup/.state/values-region.yaml` | 600 | Rendered helm values (contains HMAC secret + Daytona API key) |
| `scripts/gcs-setup/.state/values-sshgateway-key.yaml` | 600 | Region-scoped ssh-gateway key overlay — pass with `-f` on every manual `helm upgrade` |
| `scripts/gcs-setup/.state/ssh-client{,.pub}`, `ssh-gateway-host` | 600 | SSH gateway keypairs (reused on re-runs) |

`hmac.env` is your full storage credential — guard like a secret.

## Why GKE Standard, not Autopilot?

GKE Autopilot is the simpler managed path, but it explicitly blocks privileged Pods and requires every workload to fit a narrow allowlist. The Daytona runner DaemonSet:

- runs as `securityContext.privileged: true`
- uses `hostPID: true` and `hostNetwork: true`
- mounts `hostPath: /` for the `nsenter -t 1` host-namespace escape
- runs sysbox-runc to launch sandbox containers with privileged-like semantics under the hood

These are all incompatible with Autopilot's threat model. Use Standard.
