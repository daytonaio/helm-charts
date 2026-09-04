# daytona-region Quickstart

This guide walks through deploying a single Daytona region (`proxy`, `ssh-gateway`, `runner-manager`, and the `runner` DaemonSet) into an existing Kubernetes cluster using the `daytona-region` Helm chart.

## Prerequisites

- A working Kubernetes cluster with `kubectl` context set to it.
- [Helm](https://helm.sh/docs/intro/install/) 3.x on your workstation.
- An ingress controller reachable from the public internet (the chart defaults to `nginx`). The proxy ingress uses a wildcard host derived from `proxyUrl`, so your DNS and TLS setup must cover `*.<proxy-host>`.
- A DNS record resolving to your ingress controller for `proxyUrl`. The SSH gateway is a separate `LoadBalancer` Service with its own address (NOT the ingress) — the post-install step below registers it with Daytona Cloud by IP, or you can point a DNS record at the gateway LB.
- A Daytona API endpoint and API key (`daytonaApiUrl`, `daytonaApiKey`).
- At least one node labelled and tainted to host runner pods:
  - label: `daytona-sandbox-c=true`
  - taint: `sandbox=true:NoSchedule`

## 1. Create a namespace

Pick a namespace (this guide uses `daytona`; replace as desired). Create it if it does not already exist:

```bash
kubectl create namespace daytona
```

All `kubectl`/`helm` commands below should target this namespace; the examples pass `-n daytona` — change that flag if you used a different namespace.

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
    # BOOTSTRAP value — replaced after install. The gateway validates every SSH
    # session against the Daytona API with this key; only the REGION-SCOPED key
    # works there (an org `dtn_` key boots fine but 403s on session validation).
    # That key can only be fetched after registration: see step 3b.
    apiKey: "<your dtn_ org API key>"
    sshKeys:
      privClientSSHKey: "<base64 OPENSSH PRIVATE KEY>"
      pubClientSSHKey: "<base64 OPENSSH PUBLIC KEY>"
      privGatewaySSHKey: "<base64 OPENSSH PRIVATE KEY>"

  runnermanager:
    enabled: true

  runner:
    enabled: true
    env:
      # base64 of the SAME client public key the gateway holds
      # (sshKeys.pubClientSSHKey). Without it, runners work but sandboxes
      # refuse SSH-gateway connections — a silent, SSH-only failure.
      SSH_PUBLIC_KEY: "<base64 OPENSSH PUBLIC KEY>"
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
# GNU coreutils (Linux):
base64 -w0 /tmp/client       # privClientSSHKey
base64 -w0 /tmp/client.pub   # pubClientSSHKey + runner SSH_PUBLIC_KEY
base64 -w0 /tmp/gateway      # privGatewaySSHKey
# macOS (BSD base64 has no -w): use `base64 -i /tmp/client` etc.
```

The client **public** key does double duty: it is `sshKeys.pubClientSSHKey` on the gateway AND `services.runner.env.SSH_PUBLIC_KEY` on the runners. They must match, or sandboxes reject the gateway's connections.

### Runner-manager credentials

The runner-manager authenticates to the Daytona API with the org key (`API_TOKEN`), which it reads from the registration secret automatically — no extra configuration is needed. `services.runnermanager.apiKeySecret` only matters if Daytona issues you a separate runner-manager `API_KEY`; leave it unset otherwise.

### Other options worth knowing

All available keys and their defaults live in [`charts/daytona-region/values.yaml`](./values.yaml). A few you will likely touch:

- `services.proxy.ingress.tls`, `services.proxy.ingress.selfSigned`, `services.proxy.ingress.certificate` — TLS setup for the proxy ingress.
- `services.runner.daemonInstaller.enabled` — pre-installs the sandbox binaries onto each runner node. Keep enabled unless you manage those binaries out-of-band.
- `services.runner.dockerInstaller.enabled` — installs Docker + Sysbox on the node. Disable if your node image already has them. The chart installs Sysbox **v0.7.1** (amd64 `.deb`, verified against the published sha256) onto Ubuntu 24.04 (noble) nodes — the same requirement the Docker install already has. A node that already has Sysbox keeps the version it was provisioned with — upgrading in place would stop dockerd and kill every sandbox on that node, so a newer pin is picked up by replacing nodes, not by re-running the installer.
- `services.snapshotManager.*` — the region's snapshot registry. A region needs it (plus `snapshotManagerUrl`) before snapshots can be created in it. `storage.driver: s3` requires REAL S3 (AWS); for everything else use `storage.driver: filesystem` with the built-in PVC — S3 shims (rclone gateway, GCS interop) break the registry's multipart-upload resume path.

## 3. Install the chart

From the repo root:

```bash
helm install region-my-1 ./charts/daytona-region \
  -f values-region-my-1.yaml \
  -n daytona
```

Helm runs a pre-install registration hook that calls the Daytona API and stores the response (region id, proxy API key, snapshot-manager credentials) in `Secret/<release>-region-config`, then installs the rest of the chart.

### 3b. Swap in the region-scoped SSH gateway key

The gateway validates every SSH session against the Daytona API. The org key you bootstrapped `services.sshGateway.apiKey` with is enough to boot, but session validation returns `403` — the gateway needs the **region-scoped** key, which can only be created once the region exists:

```bash
NS=daytona RELEASE=region-my-1
REGION_ID=$(kubectl -n $NS get secret $RELEASE-region-config -o jsonpath='{.data.id}' | base64 -d)
GW_KEY=$(curl -sf -X POST -H "Authorization: Bearer <your dtn_ org key>" \
  "https://app.daytona.io/api/regions/$REGION_ID/regenerate-ssh-gateway-api-key" | jq -r .apiKey)

helm upgrade $RELEASE ./charts/daytona-region -n $NS \
  -f values-region-my-1.yaml \
  --set services.sshGateway.apiKey="$GW_KEY"
kubectl -n $NS delete pod -l app.kubernetes.io/component=ssh-gateway   # no checksum annotation; bounce to pick up the key
```

Then tell Daytona Cloud where the gateway is (its own LoadBalancer, not the ingress):

```bash
GW_ADDR=$(kubectl -n $NS get svc $RELEASE-ssh-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sf -X PATCH -H "Authorization: Bearer <your dtn_ org key>" -H 'Content-Type: application/json' \
  -d "{\"sshGatewayUrl\":\"ssh://$GW_ADDR:2222\"}" \
  "https://app.daytona.io/api/regions/$REGION_ID"
```

The cloud setup scripts under `scripts/{aws,azure,gcs}-setup/` do both steps automatically (`omc::region_sshgateway_finalize`).

## 4. Verify the install

```bash
kubectl get pods -n daytona -l app.kubernetes.io/instance=region-my-1
```

You should see (once images are pulled):

- `...-proxy-*` — 1 pod, `Running`.
- `...-ssh-gateway-*` — 1 pod, `Running` (if enabled).
- `...-runnermanager-*` — 1 pod, `Running`.
- `...-runner-*` — 1 pod per labelled sandbox node, `2/2 Running` (runner docker-installer + daemon-binary-installer sidecars).
- `runner-<hex>` — dynamically created by `runner-manager` after scale-up, `1/1 Running`.

Quick health checks:

```bash
kubectl logs -n daytona -l app.kubernetes.io/component=runnermanager --tail=30
kubectl logs -n daytona -l app.kubernetes.io/component=runner -c daytona-binary-installer --tail=20
```

The `daytona-binary-installer` should report `installed /usr/local/bin/.tmp/binaries/daemon-amd64 (...bytes)` — this pre-stages the sandbox binary onto the node so sandbox containers can start.

## 5. Upgrade

After editing your values file:

```bash
helm upgrade region-my-1 ./charts/daytona-region \
  -f values-region-my-1.yaml \
  -n daytona
```

If you performed step 3b with `--set`, repeat the `--set services.sshGateway.apiKey=...` on every upgrade (or keep the key in a small extra values file passed via a second `-f`) — otherwise the gateway silently reverts to the bootstrap key and SSH sessions start failing with `403`.

## 6. Uninstall

```bash
helm uninstall region-my-1 -n daytona
```

Note: the region is *not* automatically deregistered from the Daytona API. Delete it through the Daytona API / dashboard separately if needed.

## Troubleshooting

- **`Error: INSTALLATION FAILED: ... is required`** — a required value is missing; see the table under "Required top-level keys".
- **Runner pods stuck `Pending`** — no node matches `nodeSelector: daytona-sandbox-c=true` or the `sandbox=true:NoSchedule` taint isn't tolerated.
- **Sandbox create fails with `exec: "/usr/local/bin/daytona": permission denied`** — the runner DaemonSet's `daytona-binary-installer` hasn't finished; wait for it to reach `Running` and re-check its logs. If it crash-loops, check that `services.runner.image.*` points to a pullable `daytona-runner` image.
- **Proxy ingress has no cert / wildcard mismatch** — verify `proxyUrl` hostname matches your TLS cert SAN (including the wildcard); see `services.proxy.ingress.selfSigned` or bring your own cert via `services.proxy.ingress.certificate`.
- **SSH connects then immediately disconnects; gateway logs `Failed to validate SSH access: 403`** — the gateway is still on the bootstrap/org `apiKey`. Run step 3b (region-scoped key).
- **Snapshots stuck in `error`, registry logs `panic ... s3-aws ... ListMultipartUploads` or pushes 502** — the snapshot-manager is pointed at an S3 shim. Use `storage.driver: filesystem` (PVC) unless your backend is real AWS S3.
- **`rm`/`cp` on `/usr/local/bin/.tmp/binaries/*` fails with `Operation not permitted` (even as root)** — expected. The `daytona-binary-installer` holds those files immutable, because each one is bind-mounted into every sandbox on the node from a single inode. To replace one by hand, `chattr -i <file>` first; the installer re-applies the attribute on its next refresh pass. Note this also means **rolling the chart back below the version that introduced it needs `chattr -i /usr/local/bin/.tmp/binaries/*` on each node first** — an older installer cannot replace a file it does not know is locked.
- **`runnermanager` pod `ImagePullBackOff`** — the `daytonaio/daytona-runner-manager` tag does not exist on Docker Hub for every release; keep the chart's pinned default or check the registry before overriding.
- **Runner DaemonSet pod `Pending` with `didn't have free ports`** — `services.runner.mainContainer.enabled: true` conflicts with manager-spawned runner pods over hostPorts 3000/2220. Leave it `false` when `runnermanager` is enabled (the manager's pods are the only ones registered with Daytona Cloud).
