# Daytona BYOC on Azure — Phased Deployment (test)

> **Kubernetes-only**
> Daytona BYOC (Bring Your Own Compute) is deployed
> **only on Kubernetes** — AKS, EKS, or GKE — using the
> [`daytona-region`](../../../charts/daytona-region/) Helm chart. The runner,
> runner-manager, proxy, snapshot-manager, and ssh-gateway all run **inside
> your cluster**. The canonical install is `helm install daytona-region
> ./charts/daytona-region/`; see
> [`charts/daytona-region/QUICKSTART.md`](../../../charts/daytona-region/QUICKSTART.md).
>
> This directory is the **phase-by-phase** variant of the
> [`scripts/azure-setup/`](../) guide, useful when you want to stop after
> an individual provisioning stage (DNS, TLS, storage, chart install) and
> inspect it before moving on. The retired VM-based bootstrap flow lives under
> [`scripts/azure-setup/.legacy/`](../.legacy/) and is **not** part of the
> supported Kubernetes-only path.

This guide walks through deploying **BYOC** on
Azure (AKS) end to end.

## What BYOC actually is

A BYOC deployment uses **Daytona Cloud** (`app.daytona.io`) as the control
plane but runs the underlying **compute** in your own cloud account. You do
this by creating a custom *region* on your own AKS cluster — the
`daytona-region` chart registers the region and deploys everything that runs
the sandboxes, including the **runner DaemonSet**.

```
         ┌─────────────────────────────────────────────────────────┐
         │                 Daytona Cloud (app.daytona.io)          │
         │  - Dashboard, API, auth, snapshot index, billing        │
         │  - Knows about your custom region by name + proxyUrl    │
         └────────────────────────┬────────────────────────────────┘
                                  │ outbound HTTPS only
                                  │ (region registration, runner heartbeats)
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  Your AKS cluster  —  daytona-region chart                     │
   │  ────────────────                                              │
   │  - region-registration-hook  ← registers the region on install│
   │  - proxy                      ← sandbox preview/toolbox traffic│
   │  - snapshot-manager           ← S3 read/write for snapshots    │
   │  - ssh-gateway                ← optional SSH into sandboxes    │
   │  - runner-manager             ← registers + scales runners     │
   │  - runner DaemonSet           ← one pod per sandbox-labelled    │
   │      ├─ docker-installer        node; bootstraps Docker+Sysbox │
   │      ├─ daytona-binary-installer  on the host via nsenter, then│
   │      └─ runner (daytona-runner) runs sandbox containers HERE   │
   │  - ingress-nginx, cert-manager                                 │
   │  - rclone S3 gateway  →  Azure Blob storage (snapshots)        │
   └──────────────────────────────────────────────────────────────┘
```

Daytona Cloud routes your SDK calls (or dashboard actions) through
your proxy (running in AKS), which forwards them to a runner pod in
the cluster, which runs the actual sandbox container on its node.

## Deployment steps

Even with this guide automating most of it, these are the actual decisions and
actions involved.

| # | Step | Automated by this setup? |
|---|---|---|
| 1 | Sign up at daytona.io | ❌ Interactive web flow |
| 2 | Create an organization | ❌ Dashboard click |
| 3 | Find and generate a personal API key at `app.daytona.io/dashboard/keys` | ❌ Manual; **the BYOC docs don't link to this page** |
| 4 | Pick a region name (lowercase, alphanumeric + `.-_`) | ✅ Auto-generated `aks-byoc-<timestamp>` |
| 5 | Pick a proxy URL (FQDN you own) | ❌ You provide `DOMAIN` env var |
| 6 | (Optional) Pick a snapshot manager URL | ✅ Derived as `snapshots.${DOMAIN}` |
| 7 | (Optional) Set up S3-compatible storage for snapshots | ✅ Azure Blob + rclone S3 gateway in cluster |
| 8 | Provision the AKS cluster | ✅ `az aks create` |
| 9 | Label + taint a node pool to host sandbox runner pods | ✅ `daytona-sandbox-c=true` label, `sandbox=true:NoSchedule` taint |
| 10 | Point DNS at the cluster's ingress LB | ✅ Cloudflare API |
| 11 | Install ingress-nginx | ✅ helm |
| 12 | Install cert-manager + ClusterIssuer for wildcard TLS | ✅ DNS-01 against Cloudflare |
| 13 | `helm install daytona-region` (registers region; brings up proxy, snapshot-manager, ssh-gateway, runner-manager, and the runner DaemonSet) | ✅ helm install |
| 14 | Wait for runner pods to roll out and the runner-manager to report runners "ready" | ✅ Polled via `kubectl` + API |
| 15 | Validate with the SDK | ✅ `e2e.sh` runs `daytona.create(target=<region>)` |

## Common pitfalls

Each of these can surface during a BYOC deployment.

1. **Runner pods need a labelled + tainted node pool, or they sit `Pending`.**
   The chart schedules the runner DaemonSet onto nodes carrying the
   `daytona-sandbox-c=true` label and tolerating the `sandbox=true:NoSchedule`
   taint. If no node matches, `helm install` still succeeds and the region
   appears in the dashboard, but the runner pods never start and
   `daytona.create(target=region)` fails with "no available runners". Label and
   taint a node pool *before* installing.

2. **Two different `dtn_xxx` API keys.** The *organization (org)* key is what the
   chart uses to register the region (and what the `runner-manager` uses to
   talk to the Daytona API as `API_TOKEN`). A separate *runner* key — the
   `runner-manager` API key — is stored in
   `Secret/<release>-daytona-region-runner-manager-api-key` and referenced via
   `services.runnermanager.apiKeySecret`. Both look identical (`dtn_...` /
   opaque strings), so it's easy to wire the wrong one into the wrong field.

3. **The runner runs in-cluster, but still bootstraps the host node.** The
   runner DaemonSet is privileged: its `docker-installer` sidecar enters the
   host namespace (via `nsenter`) to install Docker + Sysbox, and the
   `daytona-binary-installer` sidecar stages the sandbox `daemon` binary onto
   the host filesystem before the `daytona-runner` main container serves
   sandboxes. On AKS specifically, the node already ships `moby-containerd`,
   which conflicts with the `docker-ce` package — the installer detects this
   and falls back to the static `dockerd` tarball. Expect the runner pod to be
   `2/2` (or more) and to take a minute on first roll-out.

4. **Azure Blob doesn't natively speak S3.** The snapshot manager only
   speaks S3. On Azure, this means deploying a shim like rclone's
   S3 gateway (this guide) or paying for a real S3-compatible service
   (Wasabi, Backblaze). MinIO's Azure gateway is deprecated.

5. **The wildcard proxy URL needs DNS-01 TLS.** `proxy.example.com` and
   `*.proxy.example.com` must both have a trusted cert. HTTP-01 doesn't
   cover wildcards, so you need DNS-01, so you need an API token for your
   DNS provider.

6. **`helm uninstall` does NOT clean up Daytona Cloud state.** The region
   you registered stays in Daytona Cloud's database, as do any runners the
   `runner-manager` registered. You have to call the API or visit the
   dashboard. The teardown script in this repo handles this; the chart's
   README mentions it in a note that's easy to miss.

7. **Region registration is fragile to re-runs.** The chart's
   `region-registration-hook` sees that the region-config secret already
   exists and skips re-registration — but if you change the proxy URL, it
   doesn't update the API. You'd have to manually `PATCH /api/regions/<id>` or
   delete + recreate.

8. **You can't validate the region without runners.** Until the runner
   DaemonSet is `Running` and the `runner-manager` reports at least one runner
   "ready", `daytona.create(target=region)` will fail. "Did my chart install
   work?" can only be answered once the runner pods are healthy.

## What this setup requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Generate at https://app.daytona.io/dashboard/keys |
| `DOMAIN` | A subdomain you own under a Cloudflare-managed zone (e.g. `byoc.yourdomain.com`) |
| `ACME_EMAIL` | Anything — used for Let's Encrypt registration |
| `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens — "Edit zone DNS" template, scoped to your zone |
| Azure subscription | Must be PAYG or similar; Azure-for-Students has SKU/quota issues |

## How to run

```bash
cd scripts/azure-setup/test

export DAYTONA_API_KEY='dtn_paste-personal-key-here'
export DOMAIN='byoc.yourdomain.com'
export ACME_EMAIL='you@yourdomain.com'
export CLOUDFLARE_API_TOKEN='paste-cf-token'

# First full run - everything end to end (~35-45 min including AKS provision)
./repro.sh

# Iterate by phase (each stops after the named stage):
PHASE=1 ./repro.sh    # just up to cert-manager + namespace + Certificates
PHASE=2 ./repro.sh    # also blob storage + rclone gateway
PHASE=3 ./repro.sh    # also helm install (region registered + chart workloads)
PHASE=4 ./repro.sh    # also wait for the runner DaemonSet to become ready
PHASE=5 ./repro.sh    # full end-to-end SDK validation (default)

# When done:
./teardown.sh
```

The single `helm install daytona-region` in phase 3 registers the region and
brings up the proxy, snapshot-manager, ssh-gateway, runner-manager, and the
runner DaemonSet. There is no separate compute-provisioning step — the runner
pods schedule onto the sandbox-labelled node pool you set up alongside the
cluster.

## Layout

```
azure-repro/
├── repro.sh                       # main provision script (phased): AKS + DNS +
│                                  # TLS + rclone gateway, then helm install
│                                  # daytona-region (runner DaemonSet included).
├── teardown.sh                    # cleanup: deletes region (and runners) from
│                                  # Daytona Cloud, RG from Azure, A records
│                                  # from Cloudflare, local state.
├── values-region.yaml.tmpl        # daytona-region helm values (envsubst'd
│                                  # with DOMAIN, REGION_NAME, API creds, etc.)
├── rclone-deployment.yaml.tmpl    # rclone S3-gateway over Azure Blob
├── e2e.sh                         # SDK test: daytona.create(target=region)
│                                  # then code_run("print('Hello World')")
└── .state/                        # generated at runtime (region-id, names,
                                   # rclone keys, rendered manifests). gitignore.
```

## Validating each phase

At the end of every phase, you can spot-check:

```bash
# Phase 1: namespace exists, certificates issuing
kubectl get ns daytona-region
kubectl -n daytona-region get certificate

# Phase 2: rclone gateway accessible from inside the cluster
kubectl -n daytona-region exec -it deploy/rclone-s3-gateway -- \
  rclone lsd azureblob:

# Phase 3: region registered in Daytona Cloud, chart workloads coming up
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/regions | jq '.[] | {name, id, proxyUrl}'
kubectl -n daytona-region get pods -l app.kubernetes.io/instance=daytona-region

# Phase 4: runner DaemonSet rolled out, binary staged on the node
kubectl -n daytona-region get pods -l app.kubernetes.io/component=runner
kubectl -n daytona-region logs daemonset/daytona-region-runner \
  -c daytona-binary-installer --tail=20
# expect: "installed /usr/local/bin/.tmp/binaries/daemon-amd64 (...bytes)"

# Phase 5: runner registered by the runner-manager, state=ready
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/runners | jq '.[] | {id, name, state, score:.availabilityScore}'
```

## How BYOC differs from legacy self-hosted deployments

Daytona BYOC keeps the **control plane** (dashboard, API, auth, billing,
snapshot index) at `app.daytona.io` and self-hosts only the **compute** half —
the `daytona-region` chart on your own AKS/EKS/GKE cluster. BYOC on Kubernetes
is the supported way to keep compute on your network while Daytona Cloud keeps
the control plane managed.

|   | BYOC (`daytona-region` chart) |
|---|---|
| Control plane | Daytona Cloud (`app.daytona.io`) |
| API key source | Daytona Cloud dashboard |
| Postgres / Redis / Harbor | Not needed (control plane is hosted) |
| Runners | **DaemonSet pods in your AKS cluster** (one per sandbox-labelled node), scaled by the in-cluster `runner-manager` |
| When to use | Want a managed control plane, want sandbox compute on your own network |

## Known gaps in this setup

- **rclone S3 gateway TLS.** The gateway listens on plain HTTP inside the
  cluster (`secure: false` in values). Fine for testing, but for production
  the snapshot manager → rclone link should be TLS.
- **Single sandbox node pool.** This setup labels + taints one node pool for
  runner pods. Scaling out is adding nodes (or node pools) with the same
  `daytona-sandbox-c=true` label and `sandbox=true:NoSchedule` taint — the
  DaemonSet then schedules a runner pod onto each. Multi-pool / autoscaled
  setups are out of scope here.
- **Node SKU choice is opinionated.** `Standard_D4s_v3` is 4 vCPU / 16 GiB —
  good for a few small sandboxes. Real workloads usually want bigger sandbox
  nodes.

## When you've finished running it

You will have:
1. A working BYOC region on AKS with the runner DaemonSet serving sandboxes
   in-cluster
2. Working SDK calls targeting your custom region
3. Direct experience with all 8 pitfalls listed above

You can then either tear down (cheapest), keep it running to demo someone
else (~$0.50/hr for the AKS cluster), or iterate by running individual
phases as you experiment with config changes.
