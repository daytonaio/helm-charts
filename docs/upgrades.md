# Daytona BYOC Upgrades

This is the supported upgrade process for BYOC regions deployed with the
`daytona-region` chart. Components are versioned independently — **do not
expect flat version parity** across runner, runner-manager, proxy,
snapshot-manager, and ssh-gateway. The chart's pinned defaults are the blessed
combination; upgrade by upgrading the chart, not by overriding individual image
tags.

## Blessed version matrix (chart 0.2.0)

| Component | Image | Version |
|---|---|---|
| Runner | `daytonaio/daytona-runner` | chart `appVersion` (`v0.207.0`) |
| Runner manager | `daytonaio/daytona-runner-manager` | `v0.174.0-amd64` |
| Proxy | `daytonaio/daytona-proxy` | chart `appVersion` (`v0.207.0`) |
| Snapshot manager | `daytonaio/daytona-snapshot-manager` | chart `appVersion` (`v0.207.0`) |
| SSH gateway | `daytonaio/daytona-ssh-gateway` | chart `appVersion` (`v0.207.0`) |

Do not select image tags from Docker Hub by version number — tags are not
comparable across components, and some published runner-manager tags (e.g.
`*-byoc`, `*-k8s-oss`) are not compatible with this chart's runner image even
though their version numbers are higher. The matrix above is the only
supported combination; pairing anything else can break registration of new
runners.

## Upgrading the chart

```bash
helm repo update
helm upgrade <release> daytona/daytona-region -n <namespace> -f your-values.yaml
```

If you override image tags in your values, remove the overrides so the chart's
pinned defaults apply.

## Rolling runners to a new image

Upgrading the chart changes the image used for **new** runner pods; existing
runners keep running the old image until rolled. To roll without disrupting
sandboxes:

1. Scale up: create new runners on the new version (raise `MIN_RUNNERS`, or
   `POST /runners/add` on the runner-manager API).
2. Mark the old runners unschedulable — this drains them and starts sandboxes
   on the new runners.
3. Wait and verify no sandboxes remain on the old runners.
4. Delete the old runners.
5. Restore `MIN_RUNNERS` if you raised it.

## Checking what you are running

The image tag in your cluster is not authoritative for the runner version — the
runner reports its build version to Daytona Cloud. Ask Daytona support to
confirm the reported `appVersion` of your runners, or compare your deployed
tags against the matrix above:

```bash
kubectl get pods -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```
