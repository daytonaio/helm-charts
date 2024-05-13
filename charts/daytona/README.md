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
| `global.namespace` | Global namespace for all resources | `""` (uses Release.Namespace) |

### Service-Specific Configuration

#### API Service
| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.api.enabled` | Enable API service | `true` |
| `services.api.image.registry` | API image registry | `docker.io` |
| `services.api.image.repository` | API image repository | `daytonaio/daytona-api` |
| `services.api.image.tag` | API image tag | `""` (defaults to Chart.AppVersion) |
| `services.api.image.pullPolicy` | API image pull policy | `IfNotPresent` |
| `services.api.service.type` | API service type | `ClusterIP` |
| `services.api.service.port` | API service port | `3000` |
| `services.api.ingress.enabled` | Enable API ingress | `true` |
| `services.api.ingress.className` | API ingress class | `""` |
| `services.api.ingress.hosts` | API ingress hosts | `[{host: api.daytona.local, paths: [{path: /, pathType: Prefix}]}]` |
| `services.api.replicaCount` | API replica count | `1` |
| `services.api.resources` | API resource limits/requests | See values.yaml |
| `services.api.serviceAccount.create` | Create API service account | `true` |
| `services.api.env` | API environment variables | See values.yaml |

#### Proxy Service
| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.proxy.enabled` | Enable Proxy service | `true` |
| `services.proxy.image.registry` | Proxy image registry | `docker.io` |
| `services.proxy.image.repository` | Proxy image repository | `daytonaio/daytona-proxy` |
| `services.proxy.image.tag` | Proxy image tag | `""` (defaults to Chart.AppVersion) |
| `services.proxy.image.pullPolicy` | Proxy image pull policy | `IfNotPresent` |
| `services.proxy.service.type` | Proxy service type | `ClusterIP` |
| `services.proxy.service.port` | Proxy service port | `4000` |
| `services.proxy.ingress.enabled` | Enable Proxy ingress | `true` |
| `services.proxy.ingress.className` | Proxy ingress class | `""` |
| `services.proxy.ingress.hosts` | Proxy ingress hosts | `[{host: proxy.daytona.local, paths: [{path: /, pathType: Prefix}]}]` |
| `services.proxy.replicaCount` | Proxy replica count | `1` |
| `services.proxy.resources` | Proxy resource limits/requests | See values.yaml |
| `services.proxy.serviceAccount.create` | Create Proxy service account | `true` |

#### SSH Gateway Service
| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.sshGateway.enabled` | Enable SSH Gateway service | `true` |
| `services.sshGateway.image.registry` | SSH Gateway image registry | `docker.io` |
| `services.sshGateway.image.repository` | SSH Gateway image repository | `daytonaio/daytona-ssh-gateway` |
| `services.sshGateway.image.tag` | SSH Gateway image tag | `""` (defaults to Chart.AppVersion) |
| `services.sshGateway.image.pullPolicy` | SSH Gateway image pull policy | `IfNotPresent` |
| `services.sshGateway.service.type` | SSH Gateway service type | `LoadBalancer` |
| `services.sshGateway.service.port` | SSH Gateway service port | `2222` |
| `services.sshGateway.ingress.enabled` | Enable SSH Gateway ingress | `false` |
| `services.sshGateway.replicaCount` | SSH Gateway replica count | `1` |
| `services.sshGateway.resources` | SSH Gateway resource limits/requests | See values.yaml |
| `services.sshGateway.serviceAccount.create` | Create SSH Gateway service account | `true` |

#### Jaeger Service
| Parameter | Description | Default |
|-----------|-------------|---------|
| `services.jaeger.enabled` | Enable Jaeger service | `true` |
| `services.jaeger.service.type` | Jaeger service type | `ClusterIP` |
| `services.jaeger.service.port` | Jaeger service port | `4318` |
| `services.jaeger.ingress.enabled` | Enable Jaeger ingress | `false` |
| `services.jaeger.replicaCount` | Jaeger replica count | `1` |
| `services.jaeger.resources` | Jaeger resource limits/requests | See values.yaml |


## Services

The chart deploys the following services for secure AI infrastructure:

- **API**: Main Daytona API server for AI workload management (Dashboard: :3000/dashboard, Swagger: :3000/api)
- **Proxy**: Secure proxy service for AI workspace access
- **SSH Gateway**: Secure SSH gateway for AI workspace access (LoadBalancer type)
- **Jaeger**: Distributed tracing system for AI workload monitoring
- **PgAdmin**: PostgreSQL administration interface for data management
- **Harbor**: Enterprise-grade container registry for AI model containers
- **MinIO**: S3-compatible object storage for AI datasets and models
- **Keycloak**: Identity and access management for secure authentication

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
# Access: http://localhost:8083 (chart@domain.com / SuperSecret)
```
## Support

For support and questions, please refer to the [Daytona documentation](https://docs.daytona.io) or open an issue in the [Daytona repository](https://github.com/daytonaio/daytona).
