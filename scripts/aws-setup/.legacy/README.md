# Legacy AWS BYOC setup

> **⚠️ DO NOT USE FOR NEW DEPLOYMENTS.** Use [`../up.sh`](../up.sh) instead.

This directory contains the original `install.sh`-on-EC2 setup. It bootstraps a Daytona runner directly on a VM via SSM Run Command, which is the LEGACY bare-metal path that pre-dates the Kubernetes-native Helm chart.

Kept here for forensic comparison while the [upstream IRSA support gap](../../../docs/issues-summary.md) is open. Will be removed entirely in a future cleanup.

| File | Purpose |
|---|---|
| `repro.sh` | Full legacy provisioner: EKS + Cloudflare DNS + cert-manager + S3 + IAM user + EC2 runner VMs + SSM install.sh bootstrap |
| `runner-bootstrap.sh` | VM-side script that downloads and runs `install.sh` on each EC2 runner |
| `diagnose-runner.sh` | SSM-based read-only diagnostic for the systemd-installed runner |
| `ecr-setup.sh` | ECR pull-through cache + IAM role + Daytona registry registration (optional add-on) |

The canonical K8s-native path is `bash ../up.sh` — see [`../README.md`](../README.md) and [`docs/aws.md`](../../../docs/aws.md).
