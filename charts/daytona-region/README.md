# Daytona Region Helm Chart

This Helm chart deploys a custom Daytona region (a.k.a. **Bring Your Own Compute (BYOC)**): a proxy and snapshot manager for organizations that run Daytona sandboxes inside their own AWS account while keeping the Daytona control plane (API) hosted by Daytona Cloud.

## Overview

Custom regions allow organizations to:
- Run Daytona proxy in their own network for lower latency access to sandboxes
- Store sandbox snapshots **and declarative-builder build context** in their own S3-compatible storage
- Maintain data residency by keeping all sandbox data inside their AWS account — the Daytona control plane only sees control metadata, never sandbox content

## Architecture (BYOC)

A BYOC region lives entirely in your AWS account and exchanges only outbound HTTPS with Daytona Cloud:

```
Daytona Cloud (app.daytona.io)
  └─ control-plane API
       ▲
       │ outbound HTTPS only (region registration, runner heartbeats, control)
       │
Your AWS Account ─────────────────────────────────────────────
  ├─ EKS (this chart)
  │    ├─ proxy             ← sandbox preview/toolbox traffic
  │    └─ snapshot-manager  ← S3 read/write for snapshots + build context
  │
  ├─ Runner DaemonSet (this chart, one pod per node in the runner node pool)
  │    └─ pulls build context tarballs from the same S3 bucket
  │       (AWS_* env vars from the chart's runner-secrets Secret, or IRSA via the SA)
  │
  └─ S3 bucket   ← single source of truth
       used by snapshot-manager AND runner pods
```

The shared S3 bucket is the key design point: the snapshot-manager service and every runner pod both need read/write to the same bucket, otherwise the declarative builder will report S3 access errors on snapshot inspect/create. (With `storage.driver: filesystem` the snapshot-manager side moves to a PVC; the runners still need the bucket for backups and build context.)

## How Custom Regions Work

1. **Region Registration**: When this chart is installed, a pre-install hook automatically registers the region with the Daytona API using the provided `daytonaApiUrl` and `daytonaApiKey`

2. **API Response**: The Daytona API returns credentials (including `proxyApiKey`) that are stored in a Kubernetes secret

3. **Proxy Deployment**: The proxy service uses these credentials to authenticate with the Daytona API and route traffic to sandboxes

4. **Snapshot Storage**: The snapshot manager exposes your S3 bucket to runners over HTTPS, so persistent snapshots stay inside your AWS account

5. **Runner Installation**: The runner is deployed by this chart as a privileged DaemonSet that bootstraps Docker and Sysbox on each node via `nsenter` from inside the pod, then runs the `daytona-runner` binary as a Kubernetes-native main container. AWS credentials flow through the chart's `runner-secrets` Secret in `static` credential mode, or via an EKS IRSA-annotated ServiceAccount in `irsa` mode (see `services.runner.aws.credentialMode`). See [Declarative Builder Setup](#declarative-builder-setup-byoc) below

6. **Private Registry Auth (ECR, GHCR, etc.)**: Authentication for private images is **not** handled by the runner — credentials are obtained centrally by the Daytona control plane and passed to the runner per-pull. For ECR specifically, you register a cross-account IAM role at `app.daytona.io/dashboard/registries` and Daytona's broker assumes it on every pull. See [Private Registry Authentication (ECR)](#private-registry-authentication-ecr) below for the trust policy, permissions policy, and the most common debugging mistakes (including why `DOCKER_AUTH_CONFIG` injection on the runner doesn't help).

## Prerequisites

- Kubernetes 1.19+ (EKS recommended)
- Helm 3.2.0+
- A Daytona organization with API access
- DNS records pointing to your cluster's ingress
- An S3-compatible bucket (required for snapshot manager **and** declarative builder)
- IAM credentials (or IRSA on EKS) with read/write access to that bucket

## Installing the Chart

### 1. Create a values file

```yaml
# Region name - unique identifier for this region
regionName: "my-custom-region"

# Proxy URL - the full URL where the proxy will be accessible
proxyUrl: "https://proxy.mycompany.daytona.io"

# Daytona API credentials (obtain from your Daytona organization)
daytonaApiUrl: "https://app.daytona.io/api"
daytonaApiKey: "dtn_your_api_key_here"

# Enable region registration (required for first install)
registration:
  enabled: true

# Advertised to Daytona Cloud during registration; without it the chart
# registers an unroutable placeholder and runner snapshot pushes fail on DNS.
snapshotManagerUrl: "https://snapshots.mycompany.daytona.io"

# Enable the snapshot manager and configure the BYOC bucket.
# IMPORTANT: the runner DaemonSet's pods get their matching AWS_* env vars
# from services.runner.env in this same values file (the chart wires them into
# the runner Secret) — same bucket, same credentials.
services:
  snapshotManager:
    enabled: true
    ingress:
      enabled: true
      hostname: "snapshots.mycompany.daytona.io"
    storage:
      # Real AWS S3 only — use driver: filesystem (PVC) for anything else;
      # see "Choosing a storage driver" below.
      driver: "s3"
      s3:
        region: "us-east-1"
        bucket: "my-org-daytona-region-us"
        accessKey: "AKIAXXXXXXXXXX"
        secretKey: "your-secret-key"
      deleteEnabled: true

  runner:
    env:
      AWS_REGION: "us-east-1"
      AWS_DEFAULT_BUCKET: "my-org-daytona-region-us"
      AWS_ACCESS_KEY_ID: "AKIAXXXXXXXXXX"
      AWS_SECRET_ACCESS_KEY: "your-secret-key"
```

### 2. Install the chart

```bash
helm install my-region ./charts/daytona-region -f my-values.yaml
```

If you enabled the SSH gateway, finish with the post-install key swap — the region-scoped gateway key can only be fetched after registration. See [QUICKSTART step 3b](./QUICKSTART.md#3b-swap-in-the-region-scoped-ssh-gateway-key); the cloud setup scripts under `scripts/{aws,azure,gcs}-setup/` do it automatically.

## Uninstalling the Chart

```bash
helm uninstall my-region
```

**Note**: Uninstalling the chart does not automatically deregister the region from the Daytona API. You may need to manually remove the region through the Daytona dashboard or API.

## Configuration

### Required Configuration

| Parameter | Description | Example |
|-----------|-------------|---------|
| `regionName` | Unique identifier for this region | `"eu-west-region"` |
| `proxyUrl` | Full URL to the proxy service | `"https://proxy.eu.mycompany.io"` |
| `daytonaApiUrl` | Daytona API endpoint | `""` (e.g. `https://app.daytona.io/api`) |
| `daytonaApiKey` | API key for authentication | `"dtn_xxx..."` |

### Global Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageRegistry` | Global image registry override | `""` |
| `global.imagePullSecrets` | Global image pull secrets | `[]` |
| `global.storageClass` | Global storage class | `""` |
| `global.namespace` | Namespace override | `""` (uses Release.Namespace) |

### Proxy Service Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.proxy.image.repository` | Proxy image repository | `daytonaio/daytona-proxy` |
| `services.proxy.image.tag` | Proxy image tag | `""` (Chart.AppVersion) |
| `services.proxy.service.type` | Service type | `ClusterIP` |
| `services.proxy.service.port` | Service port | `4000` |
| `services.proxy.ingress.enabled` | Enable ingress | `true` |
| `services.proxy.ingress.className` | Ingress class | `"nginx"` |
| `services.proxy.ingress.tls` | Enable TLS | `true` |
| `services.proxy.ingress.selfSigned` | Generate self-signed certs | `false` |
| `services.proxy.replicaCount` | Number of replicas | `1` |
| `services.proxy.autoscaling.enabled` | Enable HPA | `false` |
| `services.proxy.resources` | Resource limits/requests | See values.yaml |

### Snapshot Manager Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.snapshotManager.enabled` | Enable snapshot manager | `false` |
| `services.snapshotManager.image.repository` | Image repository | `daytonaio/daytona-snapshot-manager` |
| `services.snapshotManager.service.port` | Service port | `5000` |
| `services.snapshotManager.ingress.enabled` | Enable ingress | `false` |
| `services.snapshotManager.ingress.hostname` | Ingress hostname (required if ingress enabled) | `""` |
| `services.snapshotManager.storage.driver` | Registry storage driver: `s3` or `filesystem` | `s3` |
| `services.snapshotManager.storage.filesystem.persistence.enabled` | Create a PVC for `filesystem` storage | `true` |
| `services.snapshotManager.storage.filesystem.persistence.size` | PVC size | `50Gi` |
| `services.snapshotManager.storage.filesystem.persistence.storageClass` | PVC storage class (empty = `global.storageClass`, else cluster default) | `""` |
| `services.snapshotManager.storage.filesystem.persistence.existingClaim` | Bind an existing PVC instead of creating one | `""` |
| `services.snapshotManager.storage.deleteEnabled` | Allow registry delete operations (needed for snapshot removal) | `false` |
| `services.snapshotManager.storage.s3.region` | S3 region | `""` |
| `services.snapshotManager.storage.s3.bucket` | S3 bucket name | `""` |
| `services.snapshotManager.storage.s3.accessKey` | S3 access key (if not using IRSA) | `""` |
| `services.snapshotManager.storage.s3.secretKey` | S3 secret key (if not using IRSA) | `""` |
| `services.snapshotManager.storage.s3.existingSecret` | Reference a pre-existing Secret with keys `accessKey`/`secretKey` | `""` |
| `services.snapshotManager.storage.s3.endpoint` | Custom S3 endpoint (e.g., MinIO) | `""` |
| `services.snapshotManager.storage.s3.encrypt` | Enable S3 server-side encryption | `false` |
| `services.snapshotManager.storage.s3.secure` | Use HTTPS for S3 connections | `true` |

> **Choosing a storage driver.** The snapshot-manager is a Docker registry (distribution v3). Its `s3` driver resumes every blob upload via `ListMultipartUploads` — a corner of the S3 API that S3 *shims* (rclone `serve s3`, GCS XML interop, most "S3-compatible" gateways) stub out or under-specify, which nil-panics the driver mid-push (clients see 502s; snapshots stick in `error`). Use `driver: s3` **only against real AWS S3**; everywhere else use `driver: filesystem`, which stores registry data on a PVC. Snapshots are rebuildable, so disk persistence is a sound trade. Runner backup storage (`services.runner.env.AWS_*`) is plain PUT/GET and works fine through shims — the constraint applies to the registry only.

## Declarative Builder Setup (BYOC)

When a user calls the declarative builder (e.g. `Image.debian_slim('3.12').pip_install(...)`), Daytona uploads the build context to the region's S3 bucket through the **snapshot-manager**, and then the **runner pod** that picks up the build downloads it from the same bucket to perform the `docker build`. If the runner can't read that bucket, snapshot creation will fail at the inspect/build step with an S3 access error.

This chart configures both halves: snapshot-manager and the runner DaemonSet. The runner gets its matching `AWS_*` env vars from the chart's `runner-secrets` Secret (in `static` credential mode) or via IRSA-annotated ServiceAccount (in `irsa` mode). The values for runner and snapshot-manager **must match** — same bucket, same region, credentials that can read and write.

### Step 1 — Create the S3 bucket and an IAM principal

Create one S3 bucket in the same AWS account as your EKS cluster and runner EC2 instances. The bucket stays private to this region.

Minimum IAM policy required by both the snapshot-manager and the runners:

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
      "arn:aws:s3:::my-org-daytona-region-us",
      "arn:aws:s3:::my-org-daytona-region-us/*"
    ]
  }]
}
```

Attach it to either an IAM user (static keys) or an IAM role (IRSA on EKS for the snapshot-manager; EC2 instance profile for the runners).

### Step 2 — Configure the snapshot-manager in this chart

```yaml
services:
  snapshotManager:
    enabled: true
    ingress:
      enabled: true
      hostname: "snapshots.mycompany.daytona.io"
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-org-daytona-region-us"
        accessKey: "AKIA..."      # or use existingSecret, or IRSA (see below)
        secretKey: "..."
```

### Step 3 — Configure the runner with the same bucket

In `static` credential mode (default), set the matching `AWS_*` keys under `services.runner.env`:

```yaml
services:
  runner:
    aws:
      credentialMode: static          # default; explicit for clarity
    env:
      AWS_REGION: "us-east-1"                           # match services.snapshotManager.storage.s3.region
      AWS_DEFAULT_BUCKET: "my-org-daytona-region-us"    # match services.snapshotManager.storage.s3.bucket
      AWS_ACCESS_KEY_ID: "AKIA..."                      # match services.snapshotManager.storage.s3.accessKey
      AWS_SECRET_ACCESS_KEY: "..."                      # match services.snapshotManager.storage.s3.secretKey
      AWS_ENDPOINT_URL: "https://s3.us-east-1.amazonaws.com"
```

The chart renders these into the `runner-secrets` Secret and the runner pod consumes them via `envFrom.secretRef`. See the IRSA flow below for the IAM-role alternative.

### Step 4 — Verify

From any SDK environment that can target the region:

```python
from daytona import Daytona, Image, CreateSnapshotParams

daytona = Daytona()
image = Image.debian_slim("3.12").pip_install(["requests"])
daytona.snapshot.create(
    CreateSnapshotParams(name="byoc-builder-smoke", image=image),
    on_logs=print,
)
```

If the snapshot reaches `active`, both halves are working. If it fails, see the troubleshooting section below.

### Using IRSA / instance profiles instead of static keys

**Snapshot-manager (EKS, via IRSA):** leave `accessKey`/`secretKey` blank and annotate the ServiceAccount:

```yaml
services:
  snapshotManager:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/daytona-region-snapshot-manager"
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-org-daytona-region-us"
```

**Runner DaemonSet (EKS IRSA):** set `services.runner.aws.credentialMode: irsa`, annotate the runner's ServiceAccount with `eks.amazonaws.com/role-arn`, and the chart will omit the static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` keys from the runner Secret entirely. The AWS SDK inside the runner container then picks up the IRSA-projected web-identity token:

```yaml
services:
  runner:
    aws:
      credentialMode: irsa
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/daytona-region-runner"
    env:
      AWS_REGION: "us-east-1"
      AWS_DEFAULT_BUCKET: "my-org-daytona-region-us"
      AWS_ENDPOINT_URL: "https://s3.us-east-1.amazonaws.com"
```

> **Note** — Upstream `daytona-runner` currently hard-requires non-empty `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` at startup (see [`docs/issues-summary.md`](../../docs/issues-summary.md)). Until that lands, set `services.runner.aws.allowEmptyStaticKeyShim: true` to have the chart emit empty-string placeholders that satisfy the validator while the AWS SDK still uses the IRSA web-identity token at runtime.

### Registration Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `registration.enabled` | Enable region registration hook | `true` |
| `registration.existingSecret` | Use existing secret for API key | `""` |
| `registration.image.repository` | Job image | `daytonaio/kubectl` |
| `registration.resources` | Job resource limits | See values.yaml |

## SSH Gateway

The `ssh-gateway` exposes sandboxes over SSH through its own `LoadBalancer` Service (port 2222) — it is NOT behind the ingress. Three pieces must line up:

| Piece | Where it lives | Notes |
|-------|----------------|-------|
| `services.sshGateway.sshKeys.*` | gateway Secret | base64 of the OpenSSH key **files** (client keypair + gateway host key). |
| `services.runner.env.SSH_PUBLIC_KEY` | runner Secret | base64 of the **same client public key**; without it sandboxes refuse gateway connections (an SSH-only, otherwise-silent failure). |
| `services.sshGateway.apiKey` | gateway Secret | must be the **region-scoped** key from `POST /regions/<id>/regenerate-ssh-gateway-api-key`. An org `dtn_` key boots the gateway but every session validation returns `403`. Bootstrap with the org key, then swap post-install (QUICKSTART step 3b). |

After the key swap, register the gateway address with Daytona Cloud (`PATCH /regions/<id>` with `sshGatewayUrl: ssh://<gateway-lb>:2222`) so the dashboard/CLI print working `ssh` commands.

## Runner Topology

With `services.runnermanager.enabled: true` (the default), the **runner-manager owns the runner pods**: it spawns them on demand, registers them with Daytona Cloud, and recycles them. The runner DaemonSet then runs **sidecars only** (`docker-installer`, `daytona-binary-installer`) to prepare each sandbox node.

Leave `services.runner.mainContainer.enabled: false` in this topology. A static main-container runner is never registered with Daytona Cloud (the manager only registers pods it created) and competes with the manager's pods for hostPorts 3000/2220 — the visible symptom is a DaemonSet pod stuck `Pending` with `didn't have free ports`. `mainContainer: true` exists for environments that run the runner process statically without the manager.

## URL Derivation

The `proxyUrl` is the source of truth for proxy configuration. The following values are automatically derived:

- **Proxy hostname**: Extracted from `proxyUrl` (e.g., `proxy.example.com`)
- **Proxy port**: Extracted from `proxyUrl` (e.g., `4000`) or defaults to standard ports
- **Protocol**: Extracted from `proxyUrl` (e.g., `https`)
- **Cookie domain**: Base domain extracted by stripping first subdomain (e.g., `example.com`)
- **Ingress hosts**: Proxy hostname + wildcard for sandbox subdomains

## TLS Configuration

The proxy ingress creates rules for both the proxy hostname and a wildcard pattern for sandbox subdomains:
- `proxy.example.com` - Main proxy endpoint
- `*.proxy.example.com` - Sandbox subdomain routing

Your TLS certificate should cover both patterns. Options:

1. **cert-manager**: Automatically provisions certificates
2. **Self-signed**: Set `services.proxy.ingress.selfSigned: true`
3. **Custom certificate**: Provide via `services.proxy.ingress.secrets`

## Private Registry Authentication (ECR)

Private-image authentication for snapshots is **handled by Daytona's control plane, not by the runner**. The runner has no `DOCKER_AUTH_CONFIG`, no Docker config-file lookup, and no `aws ecr get-login-password` code path of its own — searching this chart confirms it. Pull credentials are obtained centrally per pull and handed to the runner inline with each `INSPECT_SNAPSHOT_IN_REGISTRY` / pull job.

This section is here because the most common BYOC question — "I added `DOCKER_AUTH_CONFIG` to the runner and it still fails with `no basic auth credentials`" — is a consequence of that design and is not solvable on the runner side. The fix is always to register the registry with Daytona and let the control plane mediate.

### How the ECR auth flow works

```
1. SDK / Dashboard creates a snapshot from image
     <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>

2. Daytona API matches the image's registry hostname to a registered
   registry in your org (added at /dashboard/registries → Amazon ECR).

3. The API's "broker" principal calls sts:AssumeRole into the role ARN
   you registered, using your organization ID as ExternalId.

4. The assumed-role credentials are used to call
   ecr:GetAuthorizationToken, returning a short-lived registry token.

5. The API queues an INSPECT_SNAPSHOT_IN_REGISTRY (and later, pull) job
   for a runner. The token is attached to that job payload.

6. The runner uses the supplied token for HEAD/GET against the registry.
   It does NOT consult any local docker auth.
```

If step 2, 3, or 4 fails, step 5 still happens but with no token — the runner falls back to anonymous, ECR returns 401, and you see `no basic auth credentials` in the runner job.

### Broker principal: SaaS vs self-hosted

The "broker" in step 3 is whichever IAM principal your Daytona API server runs as. There are two cases:

| Deployment | Broker IAM principal | Notes |
|---|---|---|
| **Daytona Cloud (SaaS) BYOC** — `app.daytona.io` + this chart in your AWS account | `arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker` | Fixed SaaS broker role. Trust policy in your account allows this exact ARN. |
| **Full self-hosted Daytona** — entire stack in your AWS account | The IRSA role attached to your `daytona-api` pods' ServiceAccount | You substitute it in the trust policy. The SaaS broker ARN is irrelevant here. |

This `daytona-region` chart only covers the BYOC case (proxy + snapshot-manager in EKS, API in Daytona Cloud), so the broker is the SaaS broker ARN. BYOC on Kubernetes is the supported way to keep compute on your own network.

### Step 1 — Create the ECR puller role in your AWS account

Trust policy. Replace `<YOUR_ORG_ID>` with your Daytona organization ID (visible in the dashboard URL as `/dashboard/<orgId>/...`).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "sts:ExternalId": "<YOUR_ORG_ID>" }
    }
  }]
}
```

Permissions policy. All four actions are required — `BatchCheckLayerAvailability` and `BatchGetImage` are what `INSPECT_SNAPSHOT_IN_REGISTRY` and the pull path actually call. Dropping any of them produces the same `no basic auth credentials` symptom because Daytona treats a partial-permissions failure as an auth failure.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ],
    "Resource": "*"
  }]
}
```

`ecr:GetAuthorizationToken` requires `Resource: "*"`. The other three can be scoped to a specific repository ARN if you want (`arn:aws:ecr:<region>:<account>:repository/<repo>`).

### Step 2 — Register the registry in Daytona

At `app.daytona.io/dashboard/registries`:

1. **Add Registry** → **Amazon ECR** tab
2. **Registry URL**: `<account_id>.dkr.ecr.<region>.amazonaws.com` (no scheme, no path)
3. **Role ARN**: the ARN of the role from step 1

There is **no** password field — credentials are resolved server-side per pull via the AssumeRole flow above. Pasting an `aws ecr get-login-password` output anywhere is not the right shape and won't help.

### Step 3 — Reference the image in the snapshot

The image string must use the **same registry hostname** registered in step 2, character-for-character. ECR is strict about this:

```
123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repo/my-image:1.0.0     [ok]
123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repo/my-image:latest    [rejected: 'latest' tag is not allowed]
ecr.aws/123456789012/my-repo/my-image:1.0.0                             [rejected: wrong hostname format]
```

If the hostname doesn't match a registered registry, Daytona has no role to assume and falls through to anonymous pull.

### Why `DOCKER_AUTH_CONFIG` injection doesn't fix this

A common debugging instinct is to put a static `DOCKER_AUTH_CONFIG` (or write a Docker config file) inside the runner pod and assume `docker pull` will pick it up. Two reasons it doesn't help:

1. **`INSPECT_SNAPSHOT_IN_REGISTRY` is not `docker pull`.** It's a Daytona-internal job that queries the registry's HTTP API directly with credentials supplied by the Daytona API. It does not invoke `docker` and does not read docker's local auth state.
2. **ECR tokens last 12 hours.** Even where docker auth was honored, hardcoding a `DOCKER_AUTH_CONFIG` from `aws ecr get-login-password` would break after the next token rotation. The AssumeRole flow exists specifically so the runner gets a fresh token on every pull.

The fact that manual `aws ecr get-login-password | docker login` followed by `docker pull` works **inside** the runner pod only proves that the pod has IAM permissions to ECR — which is independent of whether Daytona's inspect job has been handed credentials.

### Troubleshooting checklist

In order of likelihood, when snapshot creation from an ECR image fails with `no basic auth credentials`:

1. **Is the registry actually registered?**
   ```
   curl -H "Authorization: Bearer $DAYTONA_API_KEY" \
     https://app.daytona.io/api/docker-registries | jq
   ```
   The registry hostname in your image reference must appear in this list.

2. **Does the role's trust policy reference the right broker?**
   For SaaS BYOC: `arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker`. Anything else (a user's ARN, an old broker ARN, the account root) will cause every AssumeRole to fail.

3. **Does the trust policy's `ExternalId` match your org ID?**
   Off-by-one typos here are silent — they look identical in the dashboard.

4. **Do all four ECR actions exist on the permissions policy?**
   `GetAuthorizationToken` + `BatchCheckLayerAvailability` + `GetDownloadUrlForLayer` + `BatchGetImage`. Missing any one of them produces the same error as missing all of them.

5. **Does the image string use the exact registered hostname?**
   `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>`. Even small variations (port suffix, alias) break the match.

6. **CloudTrail check** — if everything above looks right, look for the `AssumeRole` call in CloudTrail in the registry's account. The trust policy can be hardened with a `StringLike` on `sts:RoleSessionName` of `daytona-<orgId>-*` so these calls are easy to filter.

## S3 Authentication for Snapshot Manager

The snapshot manager supports multiple authentication methods for S3:

### 1. IRSA (IAM Roles for Service Accounts) - Recommended for AWS

```yaml
services:
  snapshotManager:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::123456789:role/daytona-snapshots"
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-snapshots"
        # No accessKey/secretKey needed
```

### 2. Static Credentials

```yaml
services:
  snapshotManager:
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-snapshots"
        accessKey: "AKIAXXXXXXXXXX"
        secretKey: "your-secret-key"
```

### 3. Existing Secret

```yaml
services:
  snapshotManager:
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-snapshots"
        existingSecret: "my-s3-credentials"
        # Secret must contain keys: accessKey, secretKey
```

## Troubleshooting

### Registration Hook Failed

Check the registration job logs:
```bash
kubectl logs -l app.kubernetes.io/component=region-registration
```

Common issues:
- Invalid API key
- Network connectivity to Daytona API
- Region name already exists

### Proxy Not Routing Traffic

1. Verify the proxy has the correct API key:
   ```bash
   kubectl get secret <release>-region-config -o yaml
   ```

2. Check proxy logs:
   ```bash
   kubectl logs -l app.kubernetes.io/component=proxy
   ```

3. Verify ingress is configured correctly:
   ```bash
   kubectl get ingress -l app.kubernetes.io/component=proxy
   ```

### Snapshot Manager S3 Errors

Check the snapshot manager logs:
```bash
kubectl logs -l app.kubernetes.io/component=snapshot-manager
```

Verify S3 credentials and bucket permissions.

### SSH sessions close immediately after the handshake

Gateway log shows `Failed to validate SSH access: 403`: the gateway is running with an org `dtn_` key (or the chart placeholder) instead of the region-scoped key. Fetch it via `POST /regions/<id>/regenerate-ssh-gateway-api-key` and roll it into `services.sshGateway.apiKey` (QUICKSTART step 3b). The gateway has no secret-checksum annotation — delete its pod after changing the key.

### Snapshots stuck in `error`; registry returns 502 on push

Snapshot-manager log shows `panic ... nil pointer` in `s3-aws.(*driver).Writer` / `ListMultipartUploads`: the registry is pointed at an S3 shim (rclone gateway, GCS interop, etc.). Switch to `services.snapshotManager.storage.driver: filesystem` — only real AWS S3 implements the multipart semantics the registry's s3 driver needs.

### runnermanager ImagePullBackOff

Not every chart `appVersion` has a matching `daytonaio/daytona-runner-manager` tag on Docker Hub. Keep the chart's pinned default tag, or verify the tag exists before overriding `services.runnermanager.image.tag`.

### ECR snapshot creation fails with `no basic auth credentials`

The runner's `INSPECT_SNAPSHOT_IN_REGISTRY` job is not the right layer to look at — it has no ECR-auth code path of its own. Credentials are obtained centrally by the Daytona API via `sts:AssumeRole` into a role you register, and handed to the runner per-job. If that flow breaks, the runner has nothing to fall back on and the inspect call goes anonymous.

Common causes, in order:

1. **The registry isn't registered.** `app.daytona.io/dashboard/registries` must list the ECR registry hostname. If it doesn't, Daytona has no role ARN to assume.
2. **The trust policy doesn't reference Daytona's broker.** For SaaS BYOC, the principal in your role's trust policy must be `arn:aws:iam::967657494466:role/DaytonaEcrCredentialBroker`.
3. **The `ExternalId` in the trust policy isn't your organization ID.** Subtle and silent.
4. **The image reference doesn't match the registered hostname.** Daytona matches by exact registry hostname; a typo or aliasing produces an anonymous pull.
5. **Permissions policy is incomplete.** All four of `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage` are required.

What does **not** fix this, despite being the most common first attempt:

- Putting a manual `DOCKER_AUTH_CONFIG` on the runner pod/DaemonSet (the inspect job doesn't read it).
- Running `aws ecr get-login-password | docker login` inside the runner pod (only affects local `docker pull`, not Daytona's inspect job).
- Attaching IRSA / instance-profile ECR permissions to the runner itself (the runner isn't the principal making the ECR call — the API is).

Full configuration and trust/permissions policy templates are in [Private Registry Authentication (ECR)](#private-registry-authentication-ecr) above.

### Declarative builder fails with S3 errors

Snapshot creation through `Image.debian_slim(...)` involves both the snapshot-manager **and** the runner pods. Both must read/write the same S3 bucket (unless the snapshot-manager uses `driver: filesystem`). Check in this order:

1. **Did the snapshot-manager start cleanly?**
   ```bash
   kubectl logs -l app.kubernetes.io/component=snapshot-manager --tail=200
   ```
   Look for `403 Forbidden`, `NoSuchBucket`, or missing-credential errors at startup. If the pod is in `CrashLoopBackOff`, the chart values under `services.snapshotManager.storage.s3.*` are the place to fix it.

2. **Does each runner pod have matching `AWS_*` env vars?**
   ```bash
   kubectl -n daytona exec daemonset/<release>-daytona-region-runner -c runner -- \
     env | grep -E '^AWS_'
   ```
   The five `AWS_*` lines must point at the **same bucket / region** as `services.snapshotManager.storage.s3.*` in this chart. Empty `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are valid only when `services.runner.aws.credentialMode: irsa` is set and the runner ServiceAccount carries the matching IRSA role-arn annotation.

3. **Can the runner reach the bucket on its own?**
   ```bash
   kubectl -n daytona exec daemonset/<release>-daytona-region-runner -c runner -- \
     aws s3 ls s3://my-org-daytona-region-us
   ```
   If this fails, the IAM policy or the network path is the problem — fix it before touching Daytona.

4. **Is it the same bucket in both places?** A common failure mode is using one bucket name in the chart values and a different bucket name on the runner. The two must match character-for-character.

## Support

For support and questions, please refer to the [Daytona documentation](https://docs.daytona.io) or contact your Daytona organization administrator.
