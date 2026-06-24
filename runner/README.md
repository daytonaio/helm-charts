# Runner Installation

> **⚠️ LEGACY FILE.** The CANONICAL Daytona BYOC install path is the Helm chart at
> [`charts/daytona-region/`](../charts/daytona-region/) (see [QUICKSTART.md](../charts/daytona-region/QUICKSTART.md)).
> The chart installs the runner as a privileged Kubernetes DaemonSet that bootstraps
> Docker + Sysbox on each node from inside the pod (via `nsenter`).
>
> The `install.sh`-on-VM flow documented later in this file is retained for
> historical bare-metal deployments ONLY (single-host, no cluster, non-K8s deployments).
> It is **not** the supported path on AKS / EKS / GKE and must not be referenced
> as the canonical install in any chart README, NOTES.txt, or values.yaml.

## Canonical install (Kubernetes-native)

The runner is deployed by `charts/daytona-region/`. It runs as a DaemonSet pod whose
`docker-installer` sidecar `nsenter`s into the host to install Docker + Sysbox, and
whose `runner` main container runs `daytona-runner` directly as a Kubernetes-native
container. No host script, no SSH.

```bash
helm install daytona-region oci://daytonaio/charts/daytona-region \
  -n daytona --create-namespace \
  --set regionName=<region> \
  --set proxyUrl=https://proxy.<your-domain> \
  --set daytonaApiUrl=https://<base-domain>/api \
  --set daytonaApiKey=<admin-api-key> \
  --set services.runner.mainContainer.enabled=true
```

For AWS-specific values (S3, IRSA, ECR), see
[`charts/daytona-region/README.md`](../charts/daytona-region/README.md#declarative-builder-setup-byoc).

## Declarative Builder Configuration (Kubernetes-native)

The runner downloads declarative-builder build-context tarballs from an S3-compatible bucket. In a BYOC region, the runner reads from the **same bucket** the region's snapshot-manager writes to. Set the runner's `AWS_*` values to match `services.snapshotManager.storage.s3.*`:

| Runner key (in `services.runner.env.*`) | Must match in `daytona-region` values                |
|------------------------------------------|----------------------------------------------------|
| `AWS_DEFAULT_BUCKET`                     | `services.snapshotManager.storage.s3.bucket`        |
| `AWS_REGION`                             | `services.snapshotManager.storage.s3.region`        |
| `AWS_ACCESS_KEY_ID`                      | `services.snapshotManager.storage.s3.accessKey` (or IRSA — see below) |
| `AWS_SECRET_ACCESS_KEY`                  | `services.snapshotManager.storage.s3.secretKey` (or IRSA — see below) |
| `AWS_ENDPOINT_URL`                       | `services.snapshotManager.storage.s3.endpoint` (only for non-AWS S3); default `https://s3.<region>.amazonaws.com` |

### Static credential mode (default)

```yaml
services:
  runner:
    aws:
      credentialMode: static
    env:
      AWS_REGION: "us-east-1"
      AWS_DEFAULT_BUCKET: "my-org-daytona-region-us"
      AWS_ACCESS_KEY_ID: "AKIA..."
      AWS_SECRET_ACCESS_KEY: "..."
      AWS_ENDPOINT_URL: "https://s3.us-east-1.amazonaws.com"
```

### IRSA mode (EKS)

```yaml
services:
  runner:
    aws:
      credentialMode: irsa
      allowEmptyStaticKeyShim: true   # until upstream daytona-runner gains default-chain support
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/daytona-runner"
    env:
      AWS_REGION: "us-east-1"
      AWS_DEFAULT_BUCKET: "my-org-daytona-region-us"
      AWS_ENDPOINT_URL: "https://s3.us-east-1.amazonaws.com"
```

See [`docs/issues-summary.md`](../docs/issues-summary.md) for the upstream gap that `allowEmptyStaticKeyShim` works around.

### Verify

```bash
kubectl -n daytona exec daemonset/<release>-daytona-region-runner -c runner -- \
  env | grep -E '^AWS_'
```

All five `AWS_*` lines should be populated (or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` empty if you're using IRSA + the shim).

### IAM policy

Minimum policy required against the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "arn:aws:s3:::<your-bucket>",
      "arn:aws:s3:::<your-bucket>/*"
    ]
  }]
}
```

For IRSA, attach the policy to the IAM role identified by
`services.runner.serviceAccount.annotations."eks.amazonaws.com/role-arn"`. The role's
trust policy must allow `sts:AssumeRoleWithWebIdentity` from the cluster's OIDC
provider with
`sub = system:serviceaccount:<namespace>:<release>-daytona-region-runner`.

---

## LEGACY: bare-metal / non-Kubernetes install (`install.sh`)

> **Not for AKS / EKS / GKE.** Use only on a single Linux VM without a cluster.
> This path predates the Helm chart and remains for historical compatibility.
> Operators on Kubernetes should use the canonical flow above.

The script in this directory installs Docker, downloads the `daytona-runner` binary,
and registers it with the Daytona API as a systemd service on a single host.

### Prerequisites (legacy)

- **Supported OS Architecture:** AMD64/x86_64
- **Docker:** Installed by the script if absent
- **Systemd:** Required for service management

### Legacy install command

The historical command is in this file's git history. **Do not link to it from any
chart README, NOTES.txt, or values.yaml** — the `hack/check-no-install-sh.sh` CI gate
fails any such reference. If you genuinely need a single-VM install for a development
laptop, consult Daytona support directly.

### Managing the legacy systemd-installed runner

```bash
sudo systemctl status daytona-runner
sudo tail -f /var/log/daytona-runner.log
sudo systemctl stop daytona-runner
```

For everything else (clusters, multi-node, production), use the
[`charts/daytona-region/` Helm chart](../charts/daytona-region/).
