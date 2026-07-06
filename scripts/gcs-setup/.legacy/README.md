# Legacy GCP BYOC setup

> **⚠️ DO NOT USE FOR NEW DEPLOYMENTS.** Use [`../up.sh`](../up.sh) instead.

This directory contains the original `install.sh`-on-GCE-VM setup. It bootstraps a Daytona runner directly on a VM via IAP-SSH, which is the LEGACY bare-metal path that pre-dates the Kubernetes-native Helm chart.

Kept here for forensic comparison while the [upstream IRSA support gap](../../../docs/issues-summary.md) is open. Will be removed entirely in a future cleanup.

| File | Purpose |
|---|---|
| `repro.sh` | Full legacy provisioner: GKE + Cloudflare DNS + cert-manager + GCS + HMAC + Secret Manager + GCE VM runner + install.sh bootstrap |
| `runner-bootstrap.sh` | VM-side script that downloads and runs `install.sh` on each GCE runner via IAP-SSH |
| `diagnose-snapshot.sh` | Read-only diagnostic for snapshot/GCS/runner issues |
| `gcr-setup.sh` | Artifact Registry + IAM SA + JSON key in Secret Manager (despite the filename, this uses AR not legacy GCR) |

The canonical K8s-native path is `bash ../up.sh` — see [`../README.md`](../README.md) and [`docs/gcp.md`](../../../docs/gcp.md).
