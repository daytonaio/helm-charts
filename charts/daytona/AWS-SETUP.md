# AWS Services Setup for Daytona Helm Chart

When deploying Daytona on AWS, you need to set up the following AWS services in addition to your EKS cluster **if not using the built-in subcharts**. This document outlines the required services and their configurations.

**Note:** The Helm chart includes built-in subcharts for PostgreSQL, Redis, MinIO (S3-compatible), and Harbor. If you choose to use these built-in services, you only need to set up EKS. ECR is only needed if you want to use private repositories instead of the default public ones. If you prefer to use external AWS services (RDS, ElastiCache, S3, etc.), follow the instructions in this document.

## Required AWS Services

### 1. **Amazon EKS (Elastic Kubernetes Service)**
- **Purpose**: Kubernetes cluster to host Daytona services
- **Requirements**:
  - EKS cluster version 1.19 or higher
  - Node groups with appropriate instance types and sizing
  - AWS Load Balancer Controller add-on (for LoadBalancer services like SSH Gateway)

### 2. **Amazon ECR (Elastic Container Registry)** (Optional)
- **Purpose**: Private container registry for Daytona service images and Harbor component images
- **When Required**: Only if you want to use a private ECR repository instead of the default public repositories (docker.io)
- **Note**: The Helm chart defaults to public repositories. ECR setup is only needed if you want to use private repositories.
- **Required Repositories** (if using ECR):
  - `daytona-api` - Daytona API service image
  - `daytona-proxy` - Daytona Proxy service image
  - `daytona-ssh-gateway` - Daytona SSH Gateway image
  - `harbor/*` - Harbor component images (if using Harbor from ECR)
- **Configuration** (if using ECR):
  - Create repositories for each image
  - Push Daytona service images and Harbor component images to ECR
  - Configure EKS cluster to authenticate with ECR
  - Set up IAM policies for EKS nodes to pull images from ECR
  - Configure `global.imageRegistry` in `values.yaml` to point to your ECR registry

### 3. **Amazon S3 Buckets**
- **Purpose**: Object storage for Daytona Sandbox Image Registry (Harbor) and Daytona workspace volumes
- **Required Buckets**:
  - **Daytona Sandbox Images Bucket**: For Daytona Sandbox Image Registry storage
    - **Service**: Harbor (subchart)
    - **Component**: Daytona Sandbox Image Registry
    - Bucket name: `daytona-sandbox-images` (or custom)
    - Lifecycle policies: Configure as needed
- **S3 IAM Policy for Daytona Sandbox Image Registry**:
  - Create IAM user with read/write permissions to the sandbox images bucket
  - Generate access key and secret key for the IAM user
  - Harbor (the underlying service) does not support IRSA, so access keys must be provided in `values.yaml`

**Example S3 IAM Policy for Daytona Sandbox Image Registry:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::daytona-sandbox-images",
        "arn:aws:s3:::daytona-sandbox-images/*"
      ]
    }
  ]
}
```

### 4. **Amazon ElastiCache for Redis (Optional)**
- **Purpose**: External Redis for Harbor and/or Daytona (alternative to subchart Redis)
- **Configuration Options**:
  - **Option A**: Use Helm chart subcharts (default)
    - Redis subchart deploys Redis within the cluster
    - No additional AWS setup required
  - **Option B**: Use ElastiCache Redis
    - Create ElastiCache Redis cluster
    - Configure in `values.yaml` via `externalRedis` section
    - Ensure EKS cluster can reach ElastiCache (same VPC or VPC peering)
- **If using ElastiCache**:
  - Create Redis cluster in same VPC as EKS
  - Configure security groups to allow access from EKS nodes
  - Set `redis.enabled: false` in `values.yaml`
  - Configure `externalRedis` section with ElastiCache endpoint

### 5. **Amazon RDS for PostgreSQL (Optional)**
- **Purpose**: External PostgreSQL for Harbor and/or Daytona (alternative to subchart PostgreSQL)
- **Configuration Options**:
  - **Option A**: Use Helm chart subcharts (default)
    - PostgreSQL subchart deploys PostgreSQL within the cluster
    - No additional AWS setup required
  - **Option B**: Use RDS PostgreSQL
    - Create RDS PostgreSQL instance
    - Configure in `values.yaml` via `externalDatabase` section
    - Ensure EKS cluster can reach RDS (same VPC or VPC peering)
- **If using RDS**:
  - Create RDS instance in same VPC as EKS
  - Configure security groups to allow access from EKS nodes
  - Set `postgresql.enabled: false` in `values.yaml`
  - Configure `externalDatabase` section with RDS endpoint

## IAM Roles and Policies Summary

1. **EKS Node Group IAM Role**:
   - `AmazonEC2ContainerRegistryReadOnly` - Pull images from ECR
   - `AmazonSSMManagedInstanceCore` - SSM access (optional)

2. **Daytona Sandbox Image Registry S3 Access**:
   - IAM user with S3 read/write policy for the sandbox images bucket
   - Access key and secret key configured in `values.yaml` (Harbor service does not support IRSA)

3. **EKS Cluster IAM Role**:
   - Standard EKS cluster permissions
   - VPC CNI, EBS CSI driver permissions (if using)

## Configuration in values.yaml

After setting up AWS services, configure the Helm chart:

```yaml
# Use ECR images
global:
  imageRegistry: "<account-id>.dkr.ecr.<region>.amazonaws.com"

# Configure Daytona Sandbox Image Registry (Harbor) to use S3 storage
harbor:
  imageChartStorage:
    type: s3
    s3:
      region: us-west-1
      bucket: daytona-sandbox-images
      accesskey: <AWS_ACCESS_KEY_ID>
      secretkey: <AWS_SECRET_ACCESS_KEY>
      # Harbor service does not support IRSA, so access keys must be provided

# Configure S3 for Daytona volumes
services:
  api:
    env:
      S3_ENDPOINT: "https://s3.<region>.amazonaws.com"
      S3_REGION: "<region>"
      # Use IAM instance profile or provide access keys
```

## Daytona Sandbox Image Registry S3 Access Configuration

The Daytona Sandbox Image Registry uses Harbor (subchart) as the underlying service. Since Harbor does not support IRSA, you must configure S3 access using IAM user credentials:

1. Create IAM user with S3 read/write policy for the sandbox images bucket
2. Generate access key and secret key for the IAM user
3. Configure in `values.yaml`:
```yaml
harbor:
  imageChartStorage:
    type: s3
    s3:
      region: us-west-1
      bucket: daytona-sandbox-images
      accesskey: <AWS_ACCESS_KEY_ID>
      secretkey: <AWS_SECRET_ACCESS_KEY>
```

Alternatively, you can use a Kubernetes secret and reference it:
```yaml
harbor:
  imageChartStorage:
    type: s3
    s3:
      existingSecret: harbor-s3-secret
      # Secret should contain keys: REGISTRY_STORAGE_S3_ACCESSKEY and REGISTRY_STORAGE_S3_SECRETKEY
```

## Network Requirements

- EKS cluster and supporting services (RDS, ElastiCache) should be in the same VPC or connected via VPC peering
- Security groups must allow traffic between:
  - EKS nodes → RDS (port 5432)
  - EKS nodes → ElastiCache Redis (port 6379)
  - EKS nodes → S3 (HTTPS, port 443)
  - EKS nodes → ECR (HTTPS, port 443)