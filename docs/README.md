# Daytona BYOC Deployment Guide

Deploy the Kubernetes-native Daytona BYOC (Bring Your Own Compute) foundation on AWS, Azure, or GCP. Each cloud has a single interactive bring-up script that creates a real cluster + storage + identity, deploys the `daytona-region` Helm chart, and prints a proxy URL where you can create a sandbox to validate the deployment.

Run these scripts from the root of your `helm-charts` checkout.

## Deployment loop (every cloud)

```
┌────────────────────────────────────────────────────────────────┐
│ 1. cd <helm-charts repo root>                                  │
│ 2. bash scripts/<aws|azure|gcs>-setup/up.sh                    │
│    (interactive prompts → cluster + storage + helm install)    │
│ 3. Copy the printed DNS records into your DNS provider         │
│ 4. Press y when DNS has propagated                             │
│ 5. Open https://app.daytona.io and find your region           │
│ 6. Create a sandbox via the web UI                             │
│ 7. (optional) bash scripts/<cloud>-setup/e2e.sh (SDK smoke)    │
│ 8. bash scripts/<cloud>-setup/teardown.sh when done            │
└────────────────────────────────────────────────────────────────┘
```

Total wall-clock for the happy path: ~30 minutes per cloud (cluster create dominates).

## Common prerequisites

| Tool | Version | Install |
|---|---|---|
| `kubectl` | any recent | `brew install kubectl` |
| `helm` | 3.14+ | `brew install helm` |
| `envsubst` | gettext | `brew install gettext` |
| `yq` | 4.x | `brew install yq` |
| `jq` | 1.6+ | `brew install jq` |
| `shellcheck` | any | `brew install shellcheck` (CI only) |

Per cloud:

| Cloud | Tool | Authentication |
|---|---|---|
| AWS | `aws` v2.34+, `eksctl` | `aws configure` (or SSO) — confirm with `aws sts get-caller-identity` |
| Azure | `az` | `az login` — confirm with `az account show` |
| GCP | `gcloud` 568+ | `gcloud auth login && gcloud auth application-default login` |

You also need:

- A **base DNS domain** you can create A/CNAME records on (e.g. `byoc.example.com`). The scripts derive `proxy.<base>`, `*.proxy.<base>`, and `snapshots.<base>` from this. Wildcard support required for sandbox subdomains.
- A **Daytona Cloud admin API key** from <https://app.daytona.io/dashboard/keys>.
- An **email address** for Let's Encrypt account registration (any address you receive mail at).

## Hard requirement: Ubuntu 24.04 nodes (NO EXCEPTIONS)

The Daytona helm chart's docker-installer downloads Ubuntu 24.04 (noble) `.deb` packages directly. Running on any other Ubuntu version will fail when the runner tries to bootstrap Docker on the node. Each `up.sh` script:

1. Explicitly requests Ubuntu 24.04 from the cloud (`amiFamily: Ubuntu2404` on EKS, `--os-sku Ubuntu2404` on AKS, `--image-type=UBUNTU_CONTAINERD` with GKE stable channel for GKE 1.31+).
2. After cluster + node pool join, calls `omc::verify_node_ubuntu "24.04"` which polls `status.nodeInfo.osImage` and **refuses to continue** if any required node is on a different Ubuntu version. Azure checks every AKS node, then checks the sandbox selector again.

There is no operator override flag. If the verify gate fails, either: (a) tear down and re-run (which requests Ubuntu 24.04 explicitly), (b) try a different cloud region where Ubuntu 24.04 is GA, or (c) upgrade your cloud CLI to one that supports Ubuntu 24.04.

## Deployment shape: BYOC region

You bring the compute (AKS/EKS/GKE), Daytona Cloud manages the control plane. Minimal infra in your account: cluster + S3-compat storage + runner DaemonSet. Each cloud has its own setup dir.

- [`aws.md`](aws.md) - EKS + S3 + IAM + optional IRSA wiring
- [`azure.md`](azure.md) - AKS + Azure Blob + in-cluster rclone S3 gateway
- [`gcp.md`](gcp.md) - GKE Standard + GCS + HMAC S3 interoperability

`e2e.sh` in each cloud setup dir is an optional SDK smoke test. The primary
entrypoint is `up.sh`.

## Troubleshooting

See [`troubleshooting.md`](troubleshooting.md) for common failure modes:
LoadBalancer pending, cert-manager challenge timeouts, runner CrashLoopBackOff,
sandbox build 403s, SSH gateway validation failures, volume preflight failures,
and the DNS-01 wildcard upgrade path.

## What success looks like

You can create a sandbox via the web UI and it reaches `Ready` state without errors. That confirms:

- The runner DaemonSet is up and registered with Daytona Cloud
- The chart's K8s-native runner main container path works
- The snapshot manager can read/write your storage bucket
- The proxy ingress + TLS + DNS chain resolves end-to-end
- The host-side `nsenter` docker + sysbox bootstrap completed on the node

## Operations

Chart-side runner hardening and operations knobs are collected in
[`operations.md`](operations.md). The cloud values templates opt into the
security defaults where appropriate.

The supported upgrade process and the blessed per-component version matrix are
in [`upgrades.md`](upgrades.md) — component versions are intentionally not in
lockstep; upgrade via the chart, not by overriding image tags.

| Improvement | Values key(s) | Doc |
|---|---|---|
| Stale runner cleanup | `services.runnerReaper` | [`operations.md`](operations.md#runner-reaper) |
| Fractional vCPU and density guidance | `services.runner.sandboxResources`, `services.api.sandboxDensity` | [`operations.md`](operations.md#sandbox-sizing-and-density) |
| Sandbox egress lockdown and DNS hardening | `services.runner.networkPolicy`, `services.runner.dockerInstaller.dns`, `services.runner.buildkit.dns` | [`operations.md`](operations.md#sandbox-network-security-and-dns) |
| Volume backends and mount-binary preflight | `services.runner.volumes`, `scripts/preflight/check-volume-backend.sh` | [`operations.md`](operations.md#sandbox-volumes) |

## Known limitations

- IRSA / Workload Identity for the runner is chart-wired but not production-functional until the runner accepts the SDK default credential chain. See [`issues-summary.md`](issues-summary.md).
- DNS-01 wildcard TLS certificate (HTTP-01 used by default — covers `proxy.<base>` + `snapshots.<base>` but not `*.proxy.<base>`)
- Snapshot-manager IRSA / Workload Identity
- Upstream-native versions of the chart-side hardening workarounds summarized in [`issues-summary.md`](issues-summary.md)
- BYOC warm pooling (future work)

## Where to file findings

- Chart-side bugs: open an issue against the helm-charts repo referencing the failing scenario from this doc.
- Upstream daytona-runner / API bugs: open an issue against `daytonaio/daytona`; use [`issues-summary.md`](issues-summary.md) as the concise context.
- Test-script bugs: open an issue against the helm-charts repo with the cloud, prompt set, and exact failing command.
