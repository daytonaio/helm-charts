# Daytona BYOC on AWS — Kubernetes-native bring-up

> **Kubernetes only.** BYOC is deployed exclusively on a managed Kubernetes
> cluster (EKS on AWS; AKS/GKE on the other clouds) using the
> [`daytona-region`](../../charts/daytona-region/) Helm chart. Standalone OSS
> or single-VM installs are no longer supported by this flow.
>
> The canonical install is `helm install daytona-region ./charts/daytona-region/`
> — see [`charts/daytona-region/QUICKSTART.md`](../../charts/daytona-region/QUICKSTART.md)
> for the chart-only walkthrough. The scripts in this directory wrap that same
> chart with the surrounding AWS plumbing (EKS, S3, IAM, ingress, DNS, TLS) so
> you can stand up a complete region in one pass.

This directory is **operator-side IaC** for a BYOC deployment on AWS. It
provisions everything a BYOC deployment needs and then installs the
`daytona-region` chart, so the friction points are concrete rather than
hypothetical. The entrypoint is [`up.sh`](./up.sh).

> The old EC2-based setup (runners as systemd services on separate VMs,
> provisioned via SSM) has been retired to [`.legacy/`](./.legacy/). It is kept
> only for forensic comparison and is **not** part of any supported flow.

## What BYOC actually is

In a BYOC deployment you use **Daytona Cloud** (`app.daytona.io`) as the
control plane but run the underlying **compute** inside your own AWS account,
by creating a custom *region* on your EKS cluster. The chart deploys the runner
fleet as a **DaemonSet inside that cluster** — there are no separate runner
VMs.

```
         ┌─────────────────────────────────────────────────────────┐
         │                 Daytona Cloud (app.daytona.io)          │
         │  - Dashboard, API, auth, snapshot index, billing        │
         │  - Knows about your custom region by name + proxyUrl    │
         └────────────────────────┬────────────────────────────────┘
                                  │ HTTPS (outbound only:
                                  │ region registration, runner heartbeats)
                                  ▼
   Your AWS account ──────────────────────────────────────────────────
   ┌─────────────────────────────────────────────────────────────────┐
   │  Your EKS cluster  (daytona-region chart + ingress + cert-manager)│
   │                                                                   │
   │   ┌────────────────────────────┐   ┌───────────────────────────┐ │
   │   │ proxy                       │   │ runner-manager (Deployment)│ │
   │   │ snapshot-manager            │   │  - registers runners with  │ │
   │   │ ssh-gateway                 │   │    Daytona Cloud           │ │
   │   │ ingress-nginx (NLB)         │   │  - scales runner pods      │ │
   │   │ cert-manager                │   └───────────────────────────┘ │
   │   └────────────────────────────┘                                  │
   │                                                                   │
   │   ┌───────────────────────────────────────────────────────────┐  │
   │   │ runner DaemonSet  (one pod per sandbox-labelled node)       │  │
   │   │   nodeSelector: daytona-sandbox-c=true                      │  │
   │   │   tolerates:    sandbox=true:NoSchedule                     │  │
   │   │   - daytona-runner main container (privileged, hostNetwork) │  │
   │   │   - docker + sysbox bootstrap sidecar (on the node)         │  │
   │   │   - daemon-binary installer sidecar                         │  │
   │   │   ► sandbox containers run HERE, inside the cluster         │  │
   │   └───────────────────────────────────────────────────────────┘  │
   └─────────────────────────────────┬─────────────────────────────────┘
                                     ▼
                          ┌────────────────────┐
                          │  S3 bucket (yours) │
                          │  - snapshot blobs  │
                          │  - builder context │
                          └────────────────────┘
        used by BOTH the snapshot-manager AND the runner DaemonSet
```

Daytona Cloud routes your SDK calls (or dashboard actions) through your proxy
(in EKS), which forwards them to a runner **pod** in the cluster, which runs the
actual sandbox container. The snapshot-manager and every runner pod read and
write the **same** S3 bucket in your account.

## What you host vs. what stays at Daytona Cloud

| Stays at Daytona Cloud (`app.daytona.io`) | Hosted by you (this directory provisions it) |
|---|---|
| Dashboard, API, auth, billing | EKS cluster |
| Snapshot **index** / metadata | `daytona-region` chart: runner DaemonSet, runner-manager, proxy, snapshot-manager, ssh-gateway |
| Region registry (region known by name + `proxyUrl`) | ingress-nginx (NLB), cert-manager + wildcard TLS |
| Per-pull private-registry credential brokering (e.g. ECR) | S3 bucket for snapshots + declarative-builder context |

## Deployment steps

Even with this setup automating most of it, these are the actual decisions and
actions involved.

| # | Step | Automated by this repro? |
|---|---|---|
| 1 | Sign up at daytona.io | ❌ Interactive web flow |
| 2 | Create an organization | ❌ Dashboard click |
| 3 | Generate an organization API key at `app.daytona.io/dashboard/keys` | ❌ Manual; you paste it in |
| 4 | Pick a region name (lowercase, alphanumeric + `.-_`) | ✅ Defaults to the cluster name |
| 5 | Pick a base domain (FQDN you own) | ❌ You provide `BASE_DOMAIN` |
| 6 | Set up the S3 bucket + IAM principal for snapshots and the declarative builder | ✅ `aws s3api create-bucket` + IAM user (static) or IAM role (IRSA) |
| 7 | Provision the EKS cluster **with a sandbox node pool** (labelled `daytona-sandbox-c=true`, tainted `sandbox=true:NoSchedule`) | ✅ `eksctl create cluster` (VPC, node group, OIDC, addons) |
| 8 | Point DNS at the cluster's NLB | ✅ You create the printed CNAME records |
| 9 | Install ingress-nginx (NLB-backed) | ✅ helm |
| 10 | Install cert-manager + ClusterIssuer for wildcard TLS | ✅ DNS-01 / Let's Encrypt |
| 11 | `helm install daytona-region` — registers the region **and** brings up proxy, snapshot-manager, runner-manager, and the runner DaemonSet | ✅ helm install |
| 12 | Watch runner pods land on the sandbox nodes and register with Daytona Cloud | ✅ `kubectl -n daytona get pods` |
| 13 | Validate with the SDK | ✅ `e2e.sh` runs `daytona.create(target=<region>)` |

The chart's `region-registration` pre-install hook registers the region with
Daytona Cloud; the `runner-manager` Deployment then registers individual
runners and scales runner pods. There is no VM provisioning, no SSM/SSH, and
no separate runner installer to drive.

## Common pitfalls

These surface during a real deployment.

1. **The S3 bucket has to be wired up in two places, not one.** The
   snapshot-manager (in EKS) gets its credentials from
   `services.snapshotManager.storage.s3.*` in helm values. The runner
   DaemonSet ALSO needs matching `AWS_*` env vars (`AWS_REGION`,
   `AWS_DEFAULT_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `AWS_ENDPOINT_URL`) under `services.runner.env`. They must point at the
   **same bucket**. If they don't, snapshot creation via
   `Image.debian_slim(...).pip_install(...)` fails with an S3 access error at
   the inspect/build step. (This template wires both halves from the same
   prompts, so they cannot drift.)

2. **Two different `dtn_xxx` API keys.** The *organization* key is what the
   chart uses to register the region (the `daytonaApiKey` value, consumed by
   the `region-registration` hook). The *runner* key is the credential the
   `runner-manager` uses to register runner pods with Daytona Cloud — it is
   created by the registration hook and stored in the
   `<release>-daytona-region-runner-manager-api-key` Secret. They both look
   like `dtn_...`, so it's easy to confuse the org key for the runner key; you
   only ever paste the **organization** key.

3. **The wildcard proxy URL needs DNS-01 TLS.** `proxy.<base-domain>` and
   `*.proxy.<base-domain>` must both carry a trusted cert (sandbox previews
   live on the wildcard). HTTP-01 can't issue wildcards, so cert-manager must
   use DNS-01, which means an API token for your DNS provider.

4. **Sandbox nodes must be labelled and tainted before the chart lands.** The
   runner DaemonSet schedules only onto nodes with `daytona-sandbox-c=true`
   that tolerate `sandbox=true:NoSchedule`. If the node pool is missing the
   label/taint, runner pods sit `Pending` and the region advertises zero
   capacity. `up.sh` creates the node pool with both already set.

5. **Region registration is re-run on every `helm upgrade`, and it's
   fragile.** The pre-install/pre-upgrade hook is idempotent for the *happy*
   path (it detects an existing region-config secret and skips), but if that
   secret is deleted while the region still exists in Daytona Cloud, the
   re-registration POST can fail on a duplicate region name. Don't delete the
   `<release>-daytona-region-region-config` secret out from under the chart.

6. **`helm uninstall` does NOT clean up Daytona Cloud state.** The region you
   registered (and any runners) stay in Daytona Cloud's database. You have to
   call the API or visit the dashboard. The [`teardown.sh`](./teardown.sh)
   script in this directory handles deregistration as part of cleanup.

## Capacity sizing

Sandbox capacity comes from the **sandbox node pool**, not from separate VMs.
Each node that carries the `daytona-sandbox-c=true` label and tolerates the
`sandbox=true:NoSchedule` taint gets one runner DaemonSet pod; sandbox
containers are scheduled onto those nodes by the host docker daemon the runner
manages.

- Size the region by choosing the node **instance type** and the **node count**
  in the sandbox node pool (e.g. 4 × `m7i.2xlarge` = 32 vCPU / 128 GiB raw).
- Per-sandbox CPU/memory limits are controlled by Daytona Cloud's scheduler and
  the runner; with CPU over-provisioning a 32 vCPU pool comfortably hosts on the
  order of ~16 sandboxes at 4 vCPU / 4 GiB each.

Scale up or down by changing the sandbox node pool (more/larger nodes →
more/larger runner pods). For a cheap smoke test, a single small sandbox node
is enough.

## What this setup requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Organization API key from https://app.daytona.io/dashboard/keys |
| `BASE_DOMAIN` | A subdomain you own (e.g. `byoc.yourdomain.com`); the chart derives `proxy.<domain>`, `*.proxy.<domain>`, and `snapshots.<domain>` |
| Let's Encrypt email | Used for the cert-manager ClusterIssuer registration |
| DNS provider API token | For DNS-01 wildcard issuance (e.g. a Cloudflare "Edit zone DNS" token scoped to your zone) |
| AWS account | Configured `aws` CLI (profile, env keys, or SSO). Needs IAM permissions for IAM, EKS, EC2, VPC, S3, ELB, CloudFormation |
| CLIs installed locally | `aws`, `eksctl`, `kubectl`, `helm`, `envsubst`, `yq`, `jq` |

## How to run

```bash
cd scripts/aws-setup

# AWS auth - any one of these
export AWS_PROFILE=my-profile
# OR
# export AWS_ACCESS_KEY_ID='...'
# export AWS_SECRET_ACCESS_KEY='...'
# OR
# aws sso login

# Single interactive entrypoint: prompts for cluster name, base domain,
# region name, Daytona API URL + key, AWS region, S3 bucket, and credential
# mode (static IAM keys vs IRSA). Re-runnable if interrupted; state lives
# in .state/.
./up.sh
```

`up.sh` will, in order: create the EKS cluster (with OIDC) and a sandbox node
pool labelled `daytona-sandbox-c=true` + tainted `sandbox=true:NoSchedule`;
create the S3 bucket and IAM principal; install ingress-nginx and cert-manager;
print the DNS records to create and wait for propagation; render
[`values-region.yaml.tmpl`](./values-region.yaml.tmpl) and run
`helm install daytona-region ./charts/daytona-region`. The region-registration
hook registers the region, and the runner DaemonSet + runner-manager come up
inside the cluster.

When the chart is up:

```bash
# Region + region infra pods (proxy, snapshot-manager, runner-manager, runner)
kubectl -n daytona get pods

# SDK smoke test: daytona.create(target=<region>) then code_run("...")
./e2e.sh

# Tear everything down (also deregisters the region from Daytona Cloud)
./teardown.sh
```

## Layout

```
aws-setup/
├── up.sh                          # main entrypoint: EKS + sandbox node pool +
│                                  # S3 + IAM + ingress-nginx + cert-manager +
│                                  # helm install daytona-region.
├── teardown.sh                    # cleanup: deregister region from Daytona
│                                  # Cloud, helm uninstall, eksctl delete,
│                                  # S3 empty+delete, IAM, DNS, local state.
├── values-region.yaml.tmpl        # daytona-region helm values (envsubst'd
│                                  # with BASE_DOMAIN, REGION_NAME, API creds,
│                                  # S3 bucket + IAM keys / IRSA role). Wires
│                                  # snapshot-manager AND runner to the same
│                                  # bucket so the declarative builder works.
├── e2e.sh                         # SDK test: daytona.create(target=region)
│                                  # then code_run("print('Hello World')").
├── .state/                        # generated at runtime (region-id, names,
│                                  # IAM keys, rendered manifests). gitignored.
└── .legacy/                       # RETIRED EC2-on-systemd setup. Not a
                                   # supported flow; kept for comparison only.
```

## Validating each stage

```bash
# S3 + IAM: bucket and principal exist
aws s3 ls s3://<bucket>

# EKS: nodes Ready, sandbox node pool carries the label/taint
kubectl get nodes
kubectl get nodes -l daytona-sandbox-c=true \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# ingress: NLB hostname assigned
kubectl -n ingress-nginx get svc ingress-nginx-controller

# TLS: proxy + snapshot certs Ready
kubectl -n daytona get certificate

# Region registered in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/regions | jq '.[] | {name, id, proxyUrl}'

# Runner pods: one per sandbox node, plus dynamically-created runner-<hex> pods
kubectl -n daytona get pods -l app.kubernetes.io/component=runner -o wide
kubectl -n daytona logs -l app.kubernetes.io/component=runnermanager --tail=30

# Runners report 'ready' in Daytona Cloud
curl -sS -H "Authorization: Bearer $DAYTONA_API_KEY" \
  https://app.daytona.io/api/runners | jq '.[] | {id, name, state, score:.availabilityScore}'

# Confirm the runner sees the SAME S3 bucket as the snapshot-manager
kubectl -n daytona exec daemonset/daytona-region-runner -c runner -- \
  env | grep -E '^AWS_'
```

## Comparison to the Azure setup (`../azure-setup/`)

Both setups stand up the identical `daytona-region` chart — runners are a
DaemonSet inside the managed cluster in both cases. Only the cloud-specific
plumbing differs:

| | AWS (this) | Azure (`../azure-setup/`) |
|---|---|---|
| Cluster | EKS via eksctl | AKS via `az aks create` |
| Runners | DaemonSet pods in your EKS cluster | DaemonSet pods in your AKS cluster |
| Snapshot storage | Native S3 (no shim) | Azure Blob via rclone S3-gateway sidecar |
| Builder S3 endpoint | `https://s3.<region>.amazonaws.com` | `http://rclone-s3-gateway.daytona-region:8080` |
| LB | NLB (via ingress-nginx annotation) | Azure LB (via ingress-nginx default) |
| DNS records | CNAME (NLB has a hostname) | A (LB has an IP) |
| Bucket credentials | IAM user keys, or IRSA on the runner/snapshot-manager SAs | Static keys against the rclone gateway |

The AWS path is *simpler* than Azure because S3 is native (no rclone shim) and
the IAM/IRSA identity model maps cleanly onto EKS service accounts. It is
*more involved* because EKS creates more underlying resources (VPC, subnets,
NAT GW, IGW, route tables, SGs, cluster IAM roles, OIDC provider), which means
more to track and tear down.

## Known gaps in this setup

- **Static IAM keys by default.** Uses an IAM user's keys for both the
  snapshot-manager and the runner. Production should annotate the
  snapshot-manager and runner ServiceAccounts with an IRSA role ARN
  (`services.*.serviceAccount.annotations` / `services.runner.aws.credentialMode: irsa`).
  The chart supports this — see
  [`charts/daytona-region/README.md`](../../charts/daytona-region/README.md)
  and the upstream-issue note in
  [`docs/issues-summary.md`](../../docs/issues-summary.md).
- **Single sandbox node pool, public subnets.** This setup provisions one
  node group in public subnets. Real fleets want sandbox nodes spread across
  multiple AZs and, typically, private subnets with tightened security groups.
- **No node-pool autoscaler.** The sandbox node pool is a fixed size. A
  production region usually pairs the DaemonSet with the Cluster Autoscaler or
  Karpenter so new sandbox nodes (and therefore new runner pods) come up under
  load.

## When you've finished running it

You will have:
1. A working BYOC region on EKS with the runner DaemonSet scheduled onto your
   sandbox node pool — runners run inside the cluster, not on separate VMs.
2. Working SDK calls targeting your custom region.
3. Working declarative-builder snapshot creation (the runner's `AWS_*` env vars
   point at the same S3 bucket the snapshot-manager uses).
4. Direct experience with the pitfalls listed above.

You can then tear down (cheapest), keep it running to demo, or re-run `up.sh`
(it's idempotent) as you experiment.
