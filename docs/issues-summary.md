# Daytona BYOC Issues Summary

This file replaces the longer draft issue notes. Each paragraph captures the
operator-visible limitation and the expected upstream direction.

## Runner Credential Chain

The `appVersion` runner only accepts static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. For EKS IRSA the chart runs runner image `v0.222.1-irsa` when `credentialMode: irsa`. GKE and Azure Workload Identity are not supported for runner storage; use static S3-shaped credentials there.

## Runner Volume Mounts

`volume.share` cannot work with the stock runner image alone because the runner invokes a fixed `mount-s3` command, the published Alpine/musl image does not include a compatible mount tool, mount subprocesses receive a stripped environment, and `systemd-run` can be required when the host runtime path is visible. The chart provides shared mount propagation, backend shims, and preflight checks, but operators still need a runner image with the selected mount binary until upstream makes the backend pluggable and documents or ships the required runtime tools.

## Sandbox Egress Policy

Sandbox containers are attached to host Docker bridges and can otherwise reach private cluster ranges, node services, and metadata endpoints. The chart-side `services.runner.networkPolicy` enforcer blocks those paths with host iptables rules, but this is node-wide and not visible to Daytona Cloud; the upstream direction is a runner/API-owned policy model with default private-range protections and organization-level allowlists.

## Snapshot Scheduling Affinity

Snapshot placement currently uses a hard warm-runner filter, so if only one runner has a snapshot ready, same-snapshot sandbox creates can all land on that runner while other healthy runners sit idle. A better upstream model would keep warm runners preferred but not exclusive, or expose explicit prewarm controls so operators can warm more runners without relying on database-side workarounds.
