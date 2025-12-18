# Daytona Region Helm Chart

This Helm chart deploys a custom Daytona region - a proxy and snapshot manager for organizations that need to run Daytona sandboxes in their own network/cloud infrastructure.

## Overview

Custom regions allow organizations to:
- Run Daytona proxy in their own network for lower latency access to sandboxes
- Store sandbox snapshots in their own S3-compatible storage
- Maintain data residency requirements by keeping traffic within their infrastructure

## How Custom Regions Work

1. **Region Registration**: When this chart is installed, a pre-install hook automatically registers the region with the Daytona API using the provided `daytonaApiUrl` and `daytonaApiKey`

2. **API Response**: The Daytona API returns credentials (including `proxyApiKey`) that are stored in a Kubernetes secret

3. **Proxy Deployment**: The proxy service uses these credentials to authenticate with the Daytona API and route traffic to sandboxes

4. **Snapshot Storage**: The optional snapshot manager provides S3-based storage for sandbox snapshots within your infrastructure

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- A Daytona organization with API access
- DNS records pointing to your cluster's ingress
- (Optional) S3-compatible storage for snapshot manager

## Installing the Chart

### 1. Create a values file

```yaml
# Region name - unique identifier for this region
regionName: "my-custom-region"

# Proxy URL - the full URL where the proxy will be accessible
proxyUrl: "https://proxy.mycompany.daytona.io"

# Daytona API credentials (obtain from your Daytona organization)
daytonaApiUrl: "https://api.daytona.io/api"
daytonaApiKey: "dtn_your_api_key_here"

# Enable region registration (required for first install)
registration:
  enabled: true

# Optional: Snapshot manager for local snapshot storage
services:
  snapshotManager:
    enabled: true
    ingress:
      enabled: true
      hostname: "snapshots.mycompany.daytona.io"
    storage:
      s3:
        region: "us-east-1"
        bucket: "my-daytona-snapshots"
        accessKey: "AKIAXXXXXXXXXX"
        secretKey: "your-secret-key"
```

### 2. Install the chart

```bash
helm install my-region ./charts/daytona-region -f my-values.yaml
```

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
| `daytonaApiUrl` | Daytona API endpoint | `"https://api.daytona.io/api"` |
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
| `services.snapshotManager.image.repository` | Image repository | `registry` |
| `services.snapshotManager.service.port` | Service port | `5000` |
| `services.snapshotManager.ingress.enabled` | Enable ingress | `false` |
| `services.snapshotManager.ingress.hostname` | Ingress hostname (required if ingress enabled) | `""` |
| `services.snapshotManager.storage.s3.region` | S3 region | `""` |
| `services.snapshotManager.storage.s3.bucket` | S3 bucket name | `""` |
| `services.snapshotManager.storage.s3.accessKey` | S3 access key (if not using IRSA) | `""` |
| `services.snapshotManager.storage.s3.secretKey` | S3 secret key (if not using IRSA) | `""` |
| `services.snapshotManager.storage.s3.encrypt` | Enable S3 encryption | `true` |
| `services.snapshotManager.storage.s3.secure` | Use HTTPS for S3 | `true` |

### Registration Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `registration.enabled` | Enable region registration hook | `true` |
| `registration.existingSecret` | Use existing secret for API key | `""` |
| `registration.image.repository` | Job image | `daytonaio/kubectl` |
| `registration.resources` | Job resource limits | See values.yaml |

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

## Support

For support and questions, please refer to the [Daytona documentation](https://docs.daytona.io) or contact your Daytona organization administrator.
