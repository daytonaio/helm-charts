# Daytona BYOC Upgrades

This is the supported upgrade process for BYOC regions deployed with the
`daytona-region` chart. Components are versioned independently — **do not
expect flat version parity** across runner, runner-manager, proxy,
snapshot-manager, and ssh-gateway. The chart's pinned defaults are the blessed
combination; upgrade by upgrading the chart, not by overriding individual image
tags.

## Blessed version matrix (chart 0.2.2)

| Component | Image | Version |
|---|---|---|
| Runner | `daytonaio/daytona-runner` | chart `appVersion` (`v0.207.0`) |
| Runner manager | `daytonaio/daytona-runner-manager` | chart `appVersion` (`v0.207.0`, amd64-only) |
| Proxy | `daytonaio/daytona-proxy` | chart `appVersion` (`v0.207.0`) |
| Snapshot manager | `daytonaio/daytona-snapshot-manager` | chart `appVersion` (`v0.207.0`) |
| SSH gateway | `daytonaio/daytona-ssh-gateway` | chart `appVersion` (`v0.207.0`) |

Do not select image tags from Docker Hub by version number — tags are not
comparable across components, and runner-manager tags are not comparable to
each other either. Some published runner-manager tags with higher version
numbers (e.g. `v0.174.0`) are older or incomplete builds that never launch a
runner. The matrix above is the only
supported combination; pairing anything else can break registration of new
runners.

## Upgrading the chart

```bash
helm repo update
helm upgrade <release> daytona/daytona-region -n <namespace> -f your-values.yaml
```

If you override image tags in your values, remove the overrides so the chart's
pinned defaults apply.

Before every upgrade, review the rendered change. With the
[helm-diff](https://github.com/databus23/helm-diff) plugin:

```bash
helm diff upgrade <release> daytona/daytona-region -n <namespace> -f your-values.yaml
```

Pass your full values file with `-f` rather than `--reuse-values`.
`--reuse-values` reuses the values stored with the previous release and
ignores the new chart's defaults, so new keys (such as
`services.proxy.previewAuth`) come out empty and the render fails, or an old
image tag override stays in place.

## Upgrading to chart 0.2.7

- **Image tag overrides.** If your values pin `services.proxy.image.tag` (or
  any other component's tag), remove the pin unless Daytona gave it to you for
  this chart version, and check the result in the `helm diff` output.
- **Preview sign-in.** `services.proxy.previewAuth.login.enabled` defaults to
  `false`: a browser that opens a private preview without a credential gets a
  `401` instead of a redirect to Daytona sign-in, which cannot complete on your
  domain. Proxy images that predate the setting ignore it; check
  `curl -s https://<proxy-host>/health` for `"previewLogin":false`. See
  [Preview authentication](../charts/daytona-region/README.md#preview-authentication).
- **Cookie domain.** The chart no longer sets `COOKIE_DOMAIN` from `proxyUrl`
  (it used the parent domain, e.g. `example.com` for `proxy.example.com`). The
  proxy now scopes its cookies to the proxy host and its preview subdomains.
  Cookies already set under the parent domain stay in browsers until they
  expire. To keep the old behaviour, set `services.proxy.env.COOKIE_DOMAIN`.
- **Extra proxy variables.** If you set proxy variables through other means
  (for example by adding keys to the `<release>-region-config` Secret), move
  them to `services.proxy.extraEnv`. Variables the chart owns, including every
  `PREVIEW_*` variable, are rejected there; the chart's own values win over the
  Secret.
- **Probes.** The proxy now has liveness and readiness probes on `GET /health`:
  a new pod gets traffic only once it answers, and a pod that stops answering
  is restarted. Set `services.proxy.livenessProbe` or `readinessProbe` to
  `null` to turn one off.
- **Registration hook logs.** Hook logs from earlier chart versions contain the
  region's keys. See "Registration Hook Failed" in the
  [chart README](../charts/daytona-region/README.md#registration-hook-failed)
  for how to rotate them.

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
