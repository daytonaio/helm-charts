# Daytona BYOC Operations

This guide collects the operational knobs that are shared across AWS, Azure,
and GCP BYOC regions. All settings live under `charts/daytona-region` values and
are disabled by default unless a cloud setup template opts into them.

## Runner Reaper

In BYOC, Daytona Cloud owns runner state while the runner pods live in your
cluster. If a sandbox node disappears, Daytona marks the runner `unresponsive`
after missed heartbeats, but it does not automatically retire that runner or
move backed-up sandboxes elsewhere. The runner reaper CronJob calls Daytona
Cloud runner APIs for runners in the current region, marks stale runners
unschedulable and draining after a grace window, and optionally deletes runners
that are already decommissioned.

```yaml
services:
  runnerReaper:
    enabled: true
    schedule: "*/10 * * * *"
    graceSeconds: 900
    dryRun: false
    deleteDecommissioned: true
```

The API key in `daytonaApiKey` must include `read:runners`, `write:runners`,
and `delete:runners`, and the Daytona org must have runner infrastructure APIs
enabled. Start with `dryRun: true`, inspect `kubectl -n daytona logs job/<name>`,
then force a run with:

```bash
kubectl -n daytona create job --from=cronjob/<release>-runner-reaper reaper-now
```

A sandbox without a completed backup on a hard-killed node is not recoverable;
the reaper can clean up the stale runner and move only sandboxes Daytona can
restore.

## Sandbox Network Security And DNS

Sandboxes run as sysbox containers on the host Docker bridge. Without chart-side
egress controls, sandbox code can reach private cluster ranges, node services,
and cloud metadata endpoints. The egress enforcer sidecar programs host
iptables chains through `nsenter` so sandbox-originated traffic can be blocked
without breaking runner-to-sandbox control traffic.

```yaml
services:
  runner:
    networkPolicy:
      enabled: true
      policyMode: "blocklist"        # or "allowlist"
      blockCIDRs:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
        - 100.64.0.0/10
        - 169.254.0.0/16
      allowCIDRs: []
      blockHostPorts: [22, 10250]
      reconcileSeconds: 30
```

`blocklist` keeps internet egress working for package managers while blocking
private and link-local destinations. `allowlist` drops everything except
configured `allowCIDRs`, configured DNS servers, and established return flows.
The policy is node-wide for sandbox bridges, not per organization.

Pin DNS whenever you enable the policy, especially on GKE where node
`resolv.conf` commonly points at the metadata resolver:

```yaml
services:
  runner:
    dockerInstaller:
      dns: ["8.8.8.8", "1.1.1.1"]
    buildkit:
      dns:
        nameservers: ["8.8.8.8", "1.1.1.1"]
```

The Docker daemon setting covers sandbox runtime DNS. The BuildKit setting
covers snapshot build `RUN` steps, which do not reliably inherit daemon DNS.
Configured DNS resolvers are automatically exempted from the egress block list.

Verify from a sandbox and from the node:

```bash
curl -m 3 http://169.254.169.254/
nc -zv -w 3 <node-ip> 22
curl -m 5 https://github.com -o /dev/null -w '%{http_code}\n'
nslookup pypi.org

iptables -L SBX_EGRESS -n -v
iptables -L SBX_INPUT -n -v
```

## Sandbox Sizing And Density

Two knobs control per-node density: a node-level CPU reconciler and the runner
availability ceiling used by Daytona scheduling.

```yaml
services:
  runner:
    sandboxResources:
      enabled: true
      limitMillicoresPerVcpu: 250
      requestMillicoresPerVcpu: 0
  api:
    sandboxDensity:
      maxSandboxesPerNode: "100"
      # availabilityScoreThreshold: "15"
```

The CPU reconciler rewrites each new sandbox container's cgroup CPU quota on
the runner node. It preserves relative sizing, leaves unlimited containers
alone, and does not change Daytona Cloud quota accounting. Memory is not scaled:
size memory conservatively because overcommit leads to OOM kills.

The density ceiling maps to Daytona's runner availability scoring. It is a
soft ceiling: runners stop receiving new sandboxes as score drops, but very
large concurrent bursts can briefly overshoot. Pair density limits with enough
sandbox nodes and runner-manager capacity.

Reference sizes for 1-vCPU / 1-GiB sandboxes with `limitMillicoresPerVcpu: 250`:

| Target | AWS | Azure | GCP | Notes |
|---|---|---|---|---|
| ~100 sandboxes/node | `m6a.8xlarge` / `m7i.8xlarge` | `Standard_D32as_v5` / `D32s_v5` | `n2-standard-32` / `t2d-standard-32` | 32 vCPU, 128 GiB RAM, >=250 GB disk |
| ~50 sandboxes/node | `m6a.4xlarge` | `Standard_D16as_v5` | `n2-standard-16` | 16 vCPU, 64 GiB RAM |
| ~25 sandboxes/node | `m6a.2xlarge` | `Standard_D8as_v5` | `n2-standard-8` | 8 vCPU, 32 GiB RAM |

The default Docker XFS backing store is `50G`, which fits roughly 50 slim
sandboxes. Plan around `150G` for roughly 100 slim sandboxes and more for
large base images.

Verify on a sandbox node:

```bash
docker inspect <sandbox-uuid> --format '{{.HostConfig.CpuQuota}} / {{.HostConfig.CpuPeriod}}'
kubectl logs -n daytona ds/daytona-runner -c sandbox-cpu-reconciler --tail=20
```

## Sandbox Volumes

`volume.share` requires extra runner image contents and a specific runner
topology. On `charts/daytona-region`, the volume knobs require
`services.runner.mainContainer.enabled: true` because mounts attach to the
runner main container. That topology conflicts with runner-manager-spawned
runner pods over host ports, so use one runner topology per cluster.

```yaml
services:
  runner:
    volumes:
      backend: "rclone"      # "" (off) | s3 | gcs | rclone
      hostMountPath: "/mnt"
      preflight:
        enabled: true
      gcs:
        credentialsFile: ""
      rclone:
        extraArgs: []
```

When a backend is set, the chart bind-mounts `hostMountPath` with
Bidirectional propagation so FUSE mounts created by the runner become visible
to host dockerd. For `gcs` and `rclone`, it also injects a `mount-s3` shim that
translates the runner's fixed mount command into the selected backend. A
preflight hook Job runs before install/upgrade and fails early if the selected
runner image does not contain the needed binary.

| Backend | Required binary in runner image | Credential path | Use for |
|---|---|---|---|
| `s3` | `mount-s3` | `services.runner.env.AWS_*` | Real AWS S3 with a glibc-based runner image |
| `gcs` | `gcsfuse` | `volumes.gcs.credentialsFile` | Native GCS buckets with a mounted service-account key |
| `rclone` | `rclone` | `AWS_*` env consumed by the shim | S3-compatible endpoints and a musl-friendly fallback |

The stock runner image is Alpine/musl and does not include mount tools.
`rclone` is usually the lowest-friction option on the stock base:

```dockerfile
FROM daytonaio/daytona-runner:v0.184.0-k8s-oss.1-amd64
RUN apk add --no-cache rclone fuse3 \
 && echo user_allow_other >> /etc/fuse.conf
```

Validate an image before changing a release:

```bash
scripts/preflight/check-volume-backend.sh rclone myregistry/daytona-runner:v0.184.0-volumes
```

Known limitations are summarized in [issues-summary.md](issues-summary.md):
ambient workload identity credentials are not forwarded to mount subprocesses,
and images without a usable mount binary cannot support volumes.
