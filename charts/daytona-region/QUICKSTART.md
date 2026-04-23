# daytona-region Quickstart

This guide walks through deploying a single Daytona region (`proxy`, `ssh-gateway`, `runner-manager`, and the `runner` DaemonSet) into an existing Kubernetes cluster using the `daytona-region` Helm chart.

## Prerequisites

- A working Kubernetes cluster with `kubectl` context set to it.
- [Helm](https://helm.sh/docs/intro/install/) 3.x on your workstation.
- An ingress controller reachable from the public internet (the chart defaults to `nginx`). The proxy ingress uses a wildcard host derived from `proxyUrl`, so your DNS and TLS setup must cover `*.<proxy-host>`.
- A DNS record resolving to your ingress controller for `proxyUrl` and, if you enable SSH, for `ssh.<baseDomain>`.
- A Daytona API endpoint and API key (`daytonaApiUrl`, `daytonaApiKey`).
- At least one node labelled and tainted to host runner pods:
  - label: `daytona-sandbox-c=true`
  - taint: `sandbox=true:NoSchedule`

## 1. Create a namespace

Pick a namespace (this guide uses `default`; replace as desired). Create it if it does not already exist:

```bash
kubectl create namespace daytona
```

All `kubectl`/`helm` commands below should target this namespace; the examples pass `-n default` — change that flag if you used a different namespace.

## 2. Create a values file

Create `values-region-<name>.yaml` at the repo root (these files are ignored by git via `.gitignore`). A minimal working file looks like this:

```yaml
regionName: "region-my-1"
proxyUrl: "https://proxy.my-region.example.com"
daytonaApiUrl: "https://daytona.io/api"
daytonaApiKey: "dtn_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

baseDomain: "my-region.example.com"

registration:
  enabled: true

services:
  proxy:
    ingress:
      enabled: true
      className: "nginx"
      selfSigned: false

  snapshotManager:
    enabled: false

  sshGateway:
    enabled: true
    service:
      type: LoadBalancer
      port: 2222
    apiKey: "replace-with-strong-random-string"
    sshKeys:
      privClientSSHKey: "<base64 OPENSSH PRIVATE KEY>"
      pubClientSSHKey: "<base64 OPENSSH PUBLIC KEY>"
      privGatewaySSHKey: "<base64 OPENSSH PRIVATE KEY>"

  runnermanager:
    enabled: true
    apiKeySecret:
      name: "region-my-1-daytona-region-runner-manager-api-key"
      key: "API_KEY"

  runner:
    enabled: true
```

### Required top-level keys

The chart will fail `helm install` with a clear error if any of these is missing:

| Key | Purpose |
| --- | --- |
| `regionName` | Unique identifier for this region; referenced by the Daytona API during registration. |
| `proxyUrl` | Public URL of the proxy service. Used to derive the wildcard ingress host (`*.<proxy-host>`). |
| `daytonaApiUrl` | URL of the Daytona control-plane API, e.g. `https://api.daytona.example.com/api`. |
| `daytonaApiKey` | API key used by the pre-install registration hook and stored in the region secret. |

### SSH gateway keys

`services.sshGateway.sshKeys.*` values must be **base64-encoded** PEM blobs (the chart writes them into a `Secret` verbatim). Generate a throwaway keypair and encode like this:

```bash
ssh-keygen -t ed25519 -N "" -C client-key -f /tmp/client -q
ssh-keygen -t ed25519 -N "" -C server-key -f /tmp/gateway -q
base64 -w0 /tmp/client       # privClientSSHKey
base64 -w0 /tmp/client.pub   # pubClientSSHKey
base64 -w0 /tmp/gateway      # privGatewaySSHKey
```

### Runner-manager API key secret

After the first install, the registration hook creates `Secret/<release>-daytona-region-runner-manager-api-key` containing the `API_KEY` the runner-manager uses to call the Daytona API. The `services.runnermanager.apiKeySecret.name` field must match this secret name — which is `<releaseName>-daytona-region-runner-manager-api-key`. If your release name is `region-test-1`, the secret is `region-test-1-daytona-region-runner-manager-api-key` (as in the example above).

### Other options worth knowing

All available keys and their defaults live in [`charts/daytona-region/values.yaml`](./values.yaml). A few you will likely touch:

- `services.proxy.ingress.tls`, `services.proxy.ingress.selfSigned`, `services.proxy.ingress.certificate` — TLS setup for the proxy ingress.
- `services.runner.daemonInstaller.enabled` — pre-installs the sandbox binaries onto each runner node. Keep enabled unless you manage those binaries out-of-band.
- `services.runner.dockerInstaller.enabled` — installs Docker + Sysbox on the node. Disable if your node image already has them.
- `services.snapshotManager.*` — only relevant if you run your own snapshot manager; set `enabled: false` otherwise.

## 3. Install the chart

From the repo root:

```bash
helm install region-my-1 ./charts/daytona-region \
  -f values-region-my-1.yaml \
  -n default
```

Helm runs a pre-install registration hook that calls the Daytona API and stores the response in a secret, then installs the rest of the chart.

## 4. Verify the install

```bash
kubectl get pods -n default -l app.kubernetes.io/instance=region-my-1
```

You should see (once images are pulled):

- `...-proxy-*` — 1 pod, `Running`.
- `...-ssh-gateway-*` — 1 pod, `Running` (if enabled).
- `...-runnermanager-*` — 1 pod, `Running`.
- `...-runner-*` — 1 pod per labelled sandbox node, `2/2 Running` (runner docker-installer + daemon-binary-installer sidecars).
- `runner-<hex>` — dynamically created by `runner-manager` after scale-up, `1/1 Running`.

Quick health checks:

```bash
kubectl logs -n default -l app.kubernetes.io/component=runnermanager --tail=30
kubectl logs -n default -l app.kubernetes.io/component=runner -c daytona-binary-installer --tail=20
```

The `daytona-binary-installer` should report `installed /usr/local/bin/.tmp/binaries/daemon-amd64 (...bytes)` — this pre-stages the sandbox binary onto the node so sandbox containers can start.

## 5. Upgrade

After editing your values file:

```bash
helm upgrade region-my-1 ./charts/daytona-region \
  -f values-region-my-1.yaml \
  -n default
```

## 6. Uninstall

```bash
helm uninstall region-my-1 -n default
```

Note: the region is *not* automatically deregistered from the Daytona API. Delete it through the Daytona API / dashboard separately if needed.

## Troubleshooting

- **`Error: INSTALLATION FAILED: ... is required`** — a required value is missing; see the table under "Required top-level keys".
- **Runner pods stuck `Pending`** — no node matches `nodeSelector: daytona-sandbox-c=true` or the `sandbox=true:NoSchedule` taint isn't tolerated.
- **Sandbox create fails with `exec: "/usr/local/bin/daytona": permission denied`** — the runner DaemonSet's `daytona-binary-installer` hasn't finished; wait for it to reach `Running` and re-check its logs. If it crash-loops, check that `services.runner.image.*` points to a pullable `daytona-runner` image.
- **Proxy ingress has no cert / wildcard mismatch** — verify `proxyUrl` hostname matches your TLS cert SAN (including the wildcard); see `services.proxy.ingress.selfSigned` or bring your own cert via `services.proxy.ingress.certificate`.
