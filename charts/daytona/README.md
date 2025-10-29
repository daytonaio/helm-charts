# Daytona Helm Chart

This Helm chart deploys the complete Daytona platform on Kubernetes - a secure infrastructure for running AI code, including all necessary services and dependencies.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+

## Installing the Chart

To install the chart with the release name `daytona`:

```bash
helm install daytona ./charts/daytona
```

To install with custom values:

```bash
helm install daytona ./charts/daytona -f my-values.yaml
```

## Uninstalling the Chart

To uninstall/delete the `daytona` deployment:

```bash
helm uninstall daytona
```

## Configuration

The following table lists the configurable parameters and their default values.

### Global Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageRegistry` | Global image registry override | `""` |
| `global.imagePullSecrets` | Global image pull secrets | `[]` |
| `global.storageClass` | Global storage class | `""` |
| `global.namespace` | Global namespace for all resources | `""` (uses Release.Namespace) |
| `baseDomain` | Base domain for Daytona services | `"daytona.example.com"` |

### API Service Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.api.image.registry` | API image registry | `docker.io` |
| `services.api.image.repository` | API image repository | `daytonaio/daytona-api` |
| `services.api.image.tag` | API image tag | `""` (defaults to Chart.AppVersion) |
| `services.api.image.pullPolicy` | API image pull policy | `IfNotPresent` |
| `services.api.service.type` | API service type | `ClusterIP` |
| `services.api.service.port` | API service port | `3000` |
| `services.api.service.annotations` | API service annotations | `{}` |
| `services.api.ingress.enabled` | Enable API ingress | `true` |
| `services.api.ingress.className` | API ingress class | `"nginx"` |
| `services.api.ingress.annotations` | API ingress annotations | `{}` |
| `services.api.ingress.hostname` | API ingress hostname | `""` (defaults to `baseDomain`) |
| `services.api.ingress.path` | API ingress path | `"/"` |
| `services.api.ingress.pathType` | API ingress path type | `"Prefix"` |
| `services.api.ingress.tls` | Enable TLS | `true` |
| `services.api.ingress.selfSigned` | Enable self-signed certificates | `true` |
| `services.api.ingress.secrets` | Custom TLS certificates | `[]` |
| `services.api.ingress.extraHosts` | Additional ingress hosts | `[]` |
| `services.api.ingress.extraPaths` | Additional ingress paths | `[]` |
| `services.api.ingress.extraTls` | Additional TLS configuration | `[]` |
| `services.api.ingress.extraRules` | Additional ingress rules | `[]` |
| `services.api.replicaCount` | API replica count | `1` |
| `services.api.resources` | API resource limits/requests | See values.yaml |
| `services.api.nodeSelector` | API node selector | `{}` |
| `services.api.tolerations` | API tolerations | `[]` |
| `services.api.affinity` | API affinity rules | `{}` |
| `services.api.annotations` | API deployment annotations | `{}` |
| `services.api.podAnnotations` | API pod annotations | `{}` |
| `services.api.serviceAccount.create` | Create API service account | `true` |
| `services.api.serviceAccount.name` | API service account name | `""` |
| `services.api.serviceAccount.annotations` | API service account annotations | `{}` |
| `services.api.env` | API environment variables (key-value pairs) | See values.yaml |
| `services.api.extraEnv` | Extra API environment variables (supports valueFrom) | `[]` |

#### API Environment Variables

The following environment variables can be set in `services.api.env`. Empty values are skipped in the deployment template:

**Application Configuration:**
- `ENVIRONMENT`: Application environment | `"production"`
- `PORT`: API port | `"3000"`

**OIDC Configuration:**
- `OIDC_CLIENT_ID`: OIDC client ID | `"daytona"`
- `OIDC_ISSUER_BASE_URL`: OIDC issuer URL (auto-generated as `https://{{baseDomain}}/idp/realms/daytona` if empty)
- `PUBLIC_OIDC_DOMAIN`: Public OIDC domain (auto-generated as `https://{{baseDomain}}/idp/realms/daytona` if empty)
- `OIDC_AUDIENCE`: OIDC audience | `"daytona"`
- `OIDC_MANAGEMENT_API_ENABLED`: Enable OIDC management API | `"false"`
- `OIDC_MANAGEMENT_API_CLIENT_ID`: OIDC management API client ID | `""`
- `OIDC_MANAGEMENT_API_CLIENT_SECRET`: OIDC management API client secret | `""`
- `OIDC_MANAGEMENT_API_AUDIENCE`: OIDC management API audience | `""`

**Dashboard Configuration:**
- `DASHBOARD_URL`: Dashboard URL (auto-generated as `https://{{baseDomain}}/dashboard` if empty)
- `DASHBOARD_BASE_API_URL`: Dashboard base API URL (auto-generated as `https://{{baseDomain}}` if empty)

**Registry Configuration (Harbor):**
When Harbor is enabled, registry URLs and credentials are automatically configured. If using an external registry, disable Harbor and set these values:
- `TRANSIENT_REGISTRY_URL`: Transient registry URL | `""`
- `TRANSIENT_REGISTRY_ADMIN`: Transient registry admin username | `""`
- `TRANSIENT_REGISTRY_PASSWORD`: Transient registry admin password | `""`
- `TRANSIENT_REGISTRY_PROJECT_ID`: Transient registry project ID | `""`
- `INTERNAL_REGISTRY_URL`: Internal registry URL | `""`
- `INTERNAL_REGISTRY_ADMIN`: Internal registry admin username | `""`
- `INTERNAL_REGISTRY_PASSWORD`: Internal registry admin password | `""`
- `INTERNAL_REGISTRY_PROJECT_ID`: Internal registry project ID | `""`

**S3 Configuration (MinIO):**
When MinIO is enabled, S3 endpoint and credentials are automatically configured. If using external S3 storage, disable MinIO and set these values:
- `S3_ENDPOINT`: S3 endpoint URL | `""`
- `S3_STS_ENDPOINT`: S3 STS endpoint URL | `""`
- `S3_REGION`: S3 region | `"us-east-1"`
- `S3_ACCESS_KEY`: S3 access key | `""`
- `S3_SECRET_KEY`: S3 secret key | `""`

**OTEL Configuration:**
- `OTEL_ENABLED`: Enable OTEL | `"true"`
- `OTEL_COLLECTOR_URL`: OTEL collector URL (auto-generated from Jaeger service if Jaeger enabled and empty)

**SMTP Configuration:**
- `SMTP_HOST`: SMTP host | `""`
- `SMTP_PORT`: SMTP port | `""`
- `SMTP_USER`: SMTP username | `""`
- `SMTP_PASSWORD`: SMTP password | `""`
- `SMTP_SECURE`: SMTP secure connection | `""`
- `SMTP_EMAIL_FROM`: SMTP email from address | `""`

**Runner Configuration:**
- `DEFAULT_RUNNER_DOMAIN`: Default runner domain | `""`
- `DEFAULT_RUNNER_API_URL`: Default runner API URL | `""`
- `DEFAULT_RUNNER_PROXY_URL`: Default runner proxy URL | `""`
- `DEFAULT_RUNNER_API_KEY`: Default runner API key | `""`
- `DEFAULT_RUNNER_CPU`: Default runner CPU | `"4"`
- `DEFAULT_RUNNER_MEMORY`: Default runner memory (GB) | `"8"`
- `DEFAULT_RUNNER_DISK`: Default runner disk (GB) | `"50"`
- `DEFAULT_RUNNER_GPU`: Default runner GPU count | `"0"`
- `DEFAULT_RUNNER_GPU_TYPE`: Default runner GPU type | `"none"`
- `DEFAULT_RUNNER_CAPACITY`: Default runner capacity | `"100"`
- `DEFAULT_RUNNER_REGION`: Default runner region | `"us"`
- `DEFAULT_RUNNER_CLASS`: Default runner class | `"small"`
- `DEFAULT_SNAPSHOT`: Default snapshot image | `"daytonaio/sandbox:0.5.0"`

**Database Configuration:**
Database configuration is automatically handled based on `postgresql.enabled`:
- If `postgresql.enabled=true`: Uses internal PostgreSQL subchart
- If `postgresql.enabled=false`: Uses `externalDatabase` configuration

**Redis Configuration:**
Redis configuration is automatically handled based on `redis.enabled`:
- If `redis.enabled=true`: Uses internal Redis subchart
- If `redis.enabled=false`: Uses `externalRedis` configuration

### Proxy Service Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.proxy.image.registry` | Proxy image registry | `docker.io` |
| `services.proxy.image.repository` | Proxy image repository | `daytonaio/daytona-proxy` |
| `services.proxy.image.tag` | Proxy image tag | `""` (defaults to Chart.AppVersion) |
| `services.proxy.image.pullPolicy` | Proxy image pull policy | `IfNotPresent` |
| `services.proxy.service.type` | Proxy service type | `ClusterIP` |
| `services.proxy.service.port` | Proxy service port | `4000` |
| `services.proxy.service.annotations` | Proxy service annotations | `{}` |
| `services.proxy.ingress.enabled` | Enable Proxy ingress | `true` |
| `services.proxy.ingress.className` | Proxy ingress class | `"nginx"` |
| `services.proxy.ingress.annotations` | Proxy ingress annotations | `{}` |
| `services.proxy.ingress.hostname` | Proxy ingress hostname | `""` (defaults to `proxy.{{baseDomain}}`) |
| `services.proxy.ingress.path` | Proxy ingress path | `"/"` |
| `services.proxy.ingress.pathType` | Proxy ingress path type | `"Prefix"` |
| `services.proxy.ingress.tls` | Enable TLS | `true` |
| `services.proxy.ingress.selfSigned` | Enable self-signed certificates | `false` |
| `services.proxy.ingress.secrets` | Custom TLS certificates (must include wildcard) | `[]` |
| `services.proxy.ingress.extraHosts` | Additional ingress hosts | `[]` |
| `services.proxy.ingress.extraPaths` | Additional ingress paths | `[]` |
| `services.proxy.ingress.extraTls` | Additional TLS configuration | `[]` |
| `services.proxy.ingress.extraRules` | Additional ingress rules | `[]` |
| `services.proxy.replicaCount` | Proxy replica count | `1` |
| `services.proxy.resources` | Proxy resource limits/requests | See values.yaml |
| `services.proxy.nodeSelector` | Proxy node selector | `{}` |
| `services.proxy.tolerations` | Proxy tolerations | `[]` |
| `services.proxy.affinity` | Proxy affinity rules | `{}` |
| `services.proxy.annotations` | Proxy deployment annotations | `{}` |
| `services.proxy.podAnnotations` | Proxy pod annotations | `{}` |
| `services.proxy.serviceAccount.create` | Create Proxy service account | `true` |
| `services.proxy.serviceAccount.name` | Proxy service account name | `""` |
| `services.proxy.serviceAccount.annotations` | Proxy service account annotations | `{}` |
| `services.proxy.env` | Proxy environment variables | See values.yaml |

#### Proxy Environment Variables

- `OIDC_CLIENT_ID`: OIDC client ID | `"daytona"`
- `OIDC_CLIENT_SECRET`: OIDC client secret | `""`
- `OIDC_DOMAIN`: OIDC domain (auto-generated as `https://{{baseDomain}}/idp/realms/daytona` if empty)
- `OIDC_AUDIENCE`: OIDC audience | `"daytona"`
- `PROXY_PORT`: Proxy port | `80`
- `PROXY_DOMAIN`: Proxy domain (auto-generated as `proxy.{{baseDomain}}:{{PROXY_PORT}}` if empty)
- `PROXY_API_KEY`: Proxy API key | `"super_secret_key"`
- `PROXY_PROTOCOL`: Proxy protocol | `"http"`

**Note:** Proxy ingress automatically includes a wildcard host (`*.hostname`) to support unique subdomains per sandbox workspace. Custom TLS certificates must include both the domain and its wildcard in the Subject Alternative Names (SAN).

### SSH Gateway Service Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.sshGateway.enabled` | Enable SSH Gateway service | `true` |
| `services.sshGateway.image.registry` | SSH Gateway image registry | `docker.io` |
| `services.sshGateway.image.repository` | SSH Gateway image repository | `daytonaio/daytona-ssh-gateway` |
| `services.sshGateway.image.tag` | SSH Gateway image tag | `""` (defaults to Chart.AppVersion) |
| `services.sshGateway.image.pullPolicy` | SSH Gateway image pull policy | `IfNotPresent` |
| `services.sshGateway.service.type` | SSH Gateway service type | `LoadBalancer` |
| `services.sshGateway.service.port` | SSH Gateway service port | `2222` |
| `services.sshGateway.service.annotations` | SSH Gateway service annotations | `{}` |
| `services.sshGateway.replicaCount` | SSH Gateway replica count | `1` |
| `services.sshGateway.resources` | SSH Gateway resource limits/requests | See values.yaml |
| `services.sshGateway.nodeSelector` | SSH Gateway node selector | `{}` |
| `services.sshGateway.tolerations` | SSH Gateway tolerations | `[]` |
| `services.sshGateway.affinity` | SSH Gateway affinity rules | `{}` |
| `services.sshGateway.annotations` | SSH Gateway deployment annotations | `{}` |
| `services.sshGateway.podAnnotations` | SSH Gateway pod annotations | `{}` |
| `services.sshGateway.serviceAccount.create` | Create SSH Gateway service account | `true` |
| `services.sshGateway.serviceAccount.name` | SSH Gateway service account name | `""` |
| `services.sshGateway.serviceAccount.annotations` | SSH Gateway service account annotations | `{}` |
| `services.sshGateway.apiKey` | API key for SSH Gateway authentication | `"supersecretapikey"` |
| `services.sshGateway.sshKeys.privClientSSHKey` | Private client SSH key (base64) | `""` |
| `services.sshGateway.sshKeys.pubClientSSHKey` | Public client SSH key (base64) | `""` |
| `services.sshGateway.sshKeys.privGatewaySSHKey` | Private gateway SSH key (base64) | `""` |
| `services.sshGateway.env` | SSH Gateway environment variables | See values.yaml |

#### SSH Gateway Environment Variables

- `SSH_GATEWAY_PORT`: SSH Gateway port | `"2222"`
- `SSH_GATEWAY_HOST`: SSH Gateway host (auto-generated as `ssh.{{baseDomain}}` if empty)

### External Database Configuration

Used when `postgresql.enabled=false`:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `externalDatabase.host` | External database host | `"daytona-postgresql"` |
| `externalDatabase.port` | External database port | `5432` |
| `externalDatabase.name` | External database name | `"daytona"` |
| `externalDatabase.user` | External database user | `"user"` |
| `externalDatabase.password` | External database password | `"pass"` |
| `externalDatabase.existingSecret` | Existing secret for database password (key: `database-password`) | `""` |
| `externalDatabase.enableTLS` | Enable TLS/SSL for database connection | `true` |
| `externalDatabase.allowSelfSignedCert` | Allow self-signed or internal certificates | `true` |

### External Redis Configuration

Used when `redis.enabled=false`:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `externalRedis.host` | External Redis host | `"daytona-redis-master"` |
| `externalRedis.port` | External Redis port | `6379` |
| `externalRedis.tls` | Enable TLS for Redis | `false` |
| `externalRedis.password` | External Redis password | `""` |
| `externalRedis.existingSecret` | Existing secret for Redis password (key: `redis-password`) | `""` |

### PostgreSQL Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgresql.enabled` | Enable PostgreSQL subchart | `true` |
| `postgresql.auth.postgresPassword` | PostgreSQL postgres user password | `"pass"` |
| `postgresql.auth.username` | PostgreSQL username | `"user"` |
| `postgresql.auth.password` | PostgreSQL password | `"pass"` |
| `postgresql.auth.database` | PostgreSQL database name | `"daytona"` |
| `postgresql.primary.persistence.enabled` | Enable PostgreSQL persistence | `true` |
| `postgresql.primary.persistence.size` | PostgreSQL persistence size | `8Gi` |

### Redis Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `redis.enabled` | Enable Redis subchart | `true` |
| `redis.auth.enabled` | Enable Redis authentication | `false` |
| `redis.persistence.enabled` | Enable Redis persistence | `true` |
| `redis.persistence.size` | Redis persistence size | `1Gi` |
| `redis.replica.replicaCount` | Redis replica count | `0` |

### Harbor Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `harbor.enabled` | Enable Harbor subchart | `true` |
| `harbor.externalURL` | Harbor external URL | `"https://harbor.daytona.example.com"` |
| `harbor.harborAdminPassword` | Harbor admin password | `"Harbor12345"` |
| `harbor.existingSecretAdminPassword` | Existing secret for Harbor admin password | `""` |
| `harbor.existingSecretAdminPasswordKey` | Key in existing secret for Harbor admin password | `"HARBOR_ADMIN_PASSWORD"` |
| `harbor.expose.type` | Harbor expose type | `"ingress"` |
| `harbor.expose.ingress.className` | Harbor ingress class | `"nginx"` |
| `harbor.expose.ingress.hosts.core` | Harbor ingress hostname | `"harbor.daytona.example.com"` |
| `harbor.expose.tls.enabled` | Enable Harbor TLS | `true` |
| `harbor.expose.tls.certSource` | Harbor TLS certificate source | `"secret"` |
| `harbor.expose.tls.secret.secretName` | Harbor TLS secret name | `"daytona.example.com-tls"` |
| `harbor.persistence.enabled` | Enable Harbor persistence | `true` |
| `harbor.persistence.persistentVolumeClaim.registry.size` | Harbor registry storage size | `5Gi` |
| `harbor.trivy.enabled` | Enable Trivy vulnerability scanner | `false` |
| `harbor.database.type` | Harbor database type | `"internal"` |
| `harbor.redis.type` | Harbor Redis type | `"internal"` |

### MinIO Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `minio.enabled` | Enable MinIO subchart | `true` |
| `minio.mode` | MinIO mode | `"standalone"` |
| `minio.rootUser` | MinIO root user | `"minioadmin"` |
| `minio.rootPassword` | MinIO root password | `"minioadmin"` |
| `minio.replicas` | MinIO replicas | `1` |
| `minio.service.type` | MinIO service type | `ClusterIP` |
| `minio.service.port` | MinIO service port | `9000` |
| `minio.consoleService.type` | MinIO console service type | `ClusterIP` |
| `minio.consoleService.port` | MinIO console service port | `9001` |
| `minio.buckets` | MinIO buckets configuration | See values.yaml |
| `minio.persistence.enabled` | Enable MinIO persistence | `true` |
| `minio.persistence.size` | MinIO persistence size | `8Gi` |

### Keycloak Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `keycloak.enabled` | Enable Keycloak subchart | `true` |
| `keycloak.production` | Enable production mode | `true` |
| `keycloak.httpEnabled` | Enable HTTP | `false` |
| `keycloak.httpRelativePath` | Keycloak HTTP relative path | `"/idp/"` |
| `keycloak.proxyHeaders` | Keycloak proxy headers | `"xforwarded"` |
| `keycloak.service.type` | Keycloak service type | `ClusterIP` |
| `keycloak.ingress.enabled` | Enable Keycloak ingress | `true` |
| `keycloak.ingress.ingressClassName` | Keycloak ingress class | `"nginx"` |
| `keycloak.ingress.hostname` | Keycloak ingress hostname | `"daytona.example.com"` |
| `keycloak.ingress.tls` | Enable Keycloak TLS | `true` |
| `keycloak.auth.adminUser` | Keycloak admin user | `"admin"` |
| `keycloak.auth.adminPassword` | Keycloak admin password | `"admin"` |
| `keycloak.keycloakConfigCli.enabled` | Enable Keycloak config CLI | `true` |
| `keycloak.keycloakConfigCli.existingConfigmap` | Existing Keycloak realm configmap | `"daytona-keycloak-realm-config"` |
| `keycloak.postgresql.enabled` | Enable Keycloak PostgreSQL | `true` |

### PgAdmin Subchart Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `pgadmin4.enabled` | Enable PgAdmin subchart | `true` |
| `pgadmin4.env.email` | PgAdmin email | `"dev@daytona.io"` |
| `pgadmin4.env.password` | PgAdmin password | `"SuperSecrets"` |
| `pgadmin4.service.type` | PgAdmin service type | `ClusterIP` |
| `pgadmin4.service.port` | PgAdmin service port | `80` |
| `pgadmin4.persistentVolume.enabled` | Enable PgAdmin persistence | `true` |
| `pgadmin4.persistentVolume.size` | PgAdmin persistence size | `1Gi` |
| `pgadmin4.serverDefinitions.enabled` | Enable PgAdmin server definitions | `true` |

### Global Configuration (Fallback)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `nodeSelector` | Global node selector (fallback) | `{}` |
| `tolerations` | Global tolerations (fallback) | `[]` |
| `affinity` | Global affinity (fallback) | `{}` |
| `podSecurityContext` | Pod security context | See values.yaml |
| `securityContext` | Container security context | See values.yaml |

## Auto-Generated Values

The following values are automatically generated from `baseDomain` if not set or empty in `services.api.env`:

- `OIDC_ISSUER_BASE_URL`: `https://{{baseDomain}}/idp/realms/daytona`
- `PUBLIC_OIDC_DOMAIN`: `https://{{baseDomain}}/idp/realms/daytona`
- `DASHBOARD_URL`: `https://{{baseDomain}}/dashboard`
- `DASHBOARD_BASE_API_URL`: `https://{{baseDomain}}`
- `SSH_GATEWAY_HOST`: `ssh.{{baseDomain}}`
- `PROXY_DOMAIN`: `proxy.{{baseDomain}}:{{PROXY_PORT}}`

When Harbor is enabled, the following are automatically configured:
- `TRANSIENT_REGISTRY_URL`: Uses `harbor.externalURL`
- `INTERNAL_REGISTRY_URL`: Uses `harbor.externalURL`
- Registry admin credentials from Harbor configuration

When MinIO is enabled, the following are automatically configured:
- `S3_ENDPOINT`: Uses MinIO service URL
- `S3_STS_ENDPOINT`: Uses MinIO service URL
- `S3_ACCESS_KEY`: Uses `minio.rootUser`
- `S3_SECRET_KEY`: Uses `minio.rootPassword`

When Jaeger is enabled, the following is automatically configured:
- `OTEL_COLLECTOR_URL`: Uses Jaeger service URL

## Services

The chart deploys the following services:

- **API**: Main Daytona API server (Dashboard: `:3000/dashboard`, Swagger: `:3000/api`)
- **Proxy**: Secure proxy service for workspace access (includes wildcard ingress for sandbox subdomains)
- **SSH Gateway**: Secure SSH gateway for workspace access (LoadBalancer type)
- **PostgreSQL**: Database for Daytona (via Bitnami chart)
- **Redis**: Cache and session store (via Bitnami chart)
- **Harbor**: Enterprise-grade container registry (via Official Harbor chart)
- **MinIO**: S3-compatible object storage (via Official MinIO chart)
- **Keycloak**: Identity and access management (via Bitnami chart)
- **PgAdmin**: PostgreSQL administration interface (via Runix community chart)

## Dependencies

- PostgreSQL (via Bitnami chart)
- Redis (via Bitnami chart)
- MinIO (via Official MinIO chart)
- PgAdmin (via Runix community chart)
- Harbor (via Official Harbor chart)
- Keycloak (via Bitnami chart)

## Access Guide

After installation, access the services using port-forwarding:

### Daytona Services
```bash
# API (Dashboard + Swagger)
kubectl port-forward svc/daytona-api 3000:3000
# Dashboard: http://localhost:3000/dashboard
# API Swagger: http://localhost:3000/api
```

### Supporting Services
```bash
# Harbor Portal
kubectl port-forward svc/harbor 8080:80
# Access: http://localhost:8080 (admin / Harbor12345)

# MinIO Console
kubectl port-forward svc/daytona-minio-console 9001:9001
# Access: http://localhost:9001 (minioadmin / minioadmin)

# Keycloak
kubectl port-forward svc/daytona-keycloak 8082:80
# Access: http://localhost:8082 (admin / admin)

# PgAdmin
kubectl port-forward svc/daytona-pgadmin4 8083:80
# Access: http://localhost:8083 (dev@daytona.io / SuperSecrets)
```

## Runner Deployment

After successfully deploying the Daytona platform, you can deploy runners on clean Linux hosts to execute AI workloads:

### 1. Generate Admin API Key
```bash
# Generate an admin API key for runner registration
kubectl exec $(kubectl get pods -l "app.kubernetes.io/name=daytona,app.kubernetes.io/component=api" -o jsonpath='{.items[0].metadata.name}') -- node dist/apps/api/main.js --create-admin-api-key "runner-admin-key" 2>/dev/null | grep "dtn"
```

### 2. Deploy Runner on Linux Host
```bash
# Download and run the runner installation script on your target Linux host
curl -sSL https://download.daytona.io/install.sh | sudo bash
```

The installation script will prompt for:
- **Daytona API URL**: `https://{{baseDomain}}/api` (or your custom domain)
- **Admin API Key**: Use the key generated in step 1

### 3. Runner Features
- Automatic binary download and installation
- System service configuration
- Connection to Daytona API
- AI workload execution capabilities
- Resource monitoring and management

## Support

For support and questions, please refer to the [Daytona documentation](https://docs.daytona.io) or open an issue in the [Daytona repository](https://github.com/daytonaio/daytona).
