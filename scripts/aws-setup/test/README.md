# Daytona BYOC on AWS — Kubernetes-native test harness

> **Kubernetes only.** BYOC is deployed exclusively on a managed Kubernetes
> cluster (EKS on AWS) using the
> [`daytona-region`](../../../charts/daytona-region/) Helm chart. There is no
> standalone OSS or single-VM path. Runners run as a **DaemonSet inside the
> cluster**, never on separate EC2 instances.
>
> The canonical install is `helm install daytona-region ./charts/daytona-region/`
> — see [`charts/daytona-region/QUICKSTART.md`](../../../charts/daytona-region/QUICKSTART.md).
> For the operator-facing bring-up wrapper, see the parent
> [`scripts/aws-setup/README.md`](../README.md).

This directory is the **end-to-end test harness** for the AWS BYOC flow. It
exercises the full deployment against a real AWS account: provision an
EKS cluster with a sandbox node pool, an S3 bucket + IAM principal, ingress +
wildcard TLS, then `helm install daytona-region` and validate that sandboxes
create and the declarative builder works.

## What BYOC actually is

In a BYOC deployment you use **Daytona Cloud** (`app.daytona.io`) as the control
plane but run the underlying **compute** inside your own AWS account by
creating a custom *region* on your EKS cluster. The `daytona-region` chart
brings up the region infrastructure **and** the runner fleet as a DaemonSet on
the cluster's sandbox node pool.

```
         ┌─────────────────────────────────────────────────────────┐
         │                 Daytona Cloud (app.daytona.io)          │
         │  - Dashboard, API, auth, snapshot index, billing        │
         │  - Knows about your custom region by name + proxyUrl    │
         └────────────────────────┬────────────────────────────────┘
                                  │ HTTPS (outbound only)
                                  ▼
   Your AWS account ──────────────────────────────────────────────────
   ┌─────────────────────────────────────────────────────────────────┐
   │  Your EKS cluster  (daytona-region chart + ingress + cert-manager)│
   │                                                                   │
   │   proxy · snapshot-manager · ssh-gateway · ingress-nginx (NLB)    │
   │   runner-manager (Deployment) — registers runners, scales pods    │
   │                                                                   │
   │   ┌───────────────────────────────────────────────────────────┐  │
   │   │ runner DaemonSet  (one pod per sandbox-labelled node)       │  │
   │   │   nodeSelector: daytona-sandbox-c=true                      │  │
   │   │   tolerates:    sandbox=true:NoSchedule                     │  │
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

Daytona Cloud routes SDK calls through your proxy (in EKS), which forwards them
to a runner **pod** in the cluster that runs the actual sandbox container. The
snapshot-manager and every runner pod read and write the **same** S3 bucket in
your account.

## What the test exercises

| # | Stage | Covered by the harness? |
|---|---|---|
| 1 | Sign up + create org at daytona.io | ❌ Interactive web flow (done once, out of band) |
| 2 | Generate an organization API key at `app.daytona.io/dashboard/keys` | ❌ Manual; you paste it in |
| 3 | Pick a region name + base domain | ✅ From prompts / env |
| 4 | S3 bucket + IAM principal (snapshots + declarative builder) | ✅ |
| 5 | EKS cluster **with a sandbox node pool** (labelled `daytona-sandbox-c=true`, tainted `sandbox=true:NoSchedule`) | ✅ |
| 6 | DNS records → cluster NLB | ✅ / prompted |
| 7 | ingress-nginx (NLB-backed) + cert-manager wildcard TLS | ✅ |
| 8 | `helm install daytona-region` — registers the region **and** brings up proxy, snapshot-manager, runner-manager, and the runner DaemonSet | ✅ |
| 9 | Runner pods land on the sandbox nodes and register with Daytona Cloud | ✅ assert via `kubectl` / API |
| 10 | SDK validation — `daytona.create(target=<region>)` + declarative builder | ✅ `e2e.sh` |

The chart's `region-registration` pre-install hook registers the region with
Daytona Cloud; the `runner-manager` Deployment registers individual runners
and scales runner pods. The harness asserts on the resulting Kubernetes
objects and the Daytona Cloud API — there is no VM provisioning, no SSM/SSH,
and no separate runner installer to drive or assert against.

## Gotchas the harness is designed to catch

1. **S3 must be wired up in two places.** The snapshot-manager reads
   `services.snapshotManager.storage.s3.*`; the runner DaemonSet reads matching
   `AWS_*` env vars under `services.runner.env`. Both must point at the **same
   bucket**, or `Image.debian_slim(...).pip_install(...)` snapshot creation
   fails with an S3 access error. The harness renders both halves from one set
   of inputs so they can't drift, and the SDK check fails loudly if they ever do.

2. **Two different `dtn_xxx` keys.** The *organization* key registers the region
   (the `daytonaApiKey` value used by the registration hook). The *runner* key
   is what the `runner-manager` uses to register runner pods; it is minted by
   the registration hook into the
   `<release>-daytona-region-runner-manager-api-key` Secret. They look
   identical (`dtn_...`); the harness only ever takes the **organization** key.

3. **Wildcard TLS requires DNS-01.** Both `proxy.<base-domain>` and
   `*.proxy.<base-domain>` need a trusted cert (sandbox previews live on the
   wildcard). HTTP-01 can't cover wildcards, so cert-manager uses DNS-01 and a
   DNS-provider API token.

4. **Sandbox nodes must be labelled and tainted before the chart lands.** The
   runner DaemonSet schedules only onto `daytona-sandbox-c=true` nodes that
   tolerate `sandbox=true:NoSchedule`. Missing label/taint ⇒ runner pods
   `Pending` ⇒ region advertises zero capacity. The harness creates the node
   pool with both set, then asserts the pods are `Running`.

5. **Region registration re-runs on every `helm upgrade` and is fragile.** The
   hook is idempotent on the happy path (it detects the existing region-config
   secret and skips), but deleting that secret while the region still exists in
   Daytona Cloud makes re-registration fail on a duplicate name. Don't delete
   `<release>-daytona-region-region-config` out from under the chart.

6. **`helm uninstall` does NOT clean up Daytona Cloud state.** The registered
   region and runners persist in Daytona Cloud's database. [`teardown.sh`](./teardown.sh)
   deregisters them via the API as part of cleanup.

## What this harness requires

| Thing | Where it comes from |
|---|---|
| `DAYTONA_API_KEY` | Organization API key from https://app.daytona.io/dashboard/keys |
| `DOMAIN` / base domain | A subdomain you own under a DNS-managed zone (e.g. `byoc.yourdomain.com`); the chart derives `proxy.<domain>`, `*.proxy.<domain>`, and `snapshots.<domain>` |
| Let's Encrypt email | Used for the cert-manager ClusterIssuer registration |
| DNS provider API token | For DNS-01 wildcard issuance (e.g. a Cloudflare "Edit zone DNS" token scoped to your zone) |
| AWS account | Configured `aws` CLI (profile, env keys, or SSO). Needs IAM permissions for IAM, EKS, EC2, VPC, S3, ELB, CloudFormation |
| CLIs installed locally | `aws`, `eksctl`, `kubectl`, `helm`, `envsubst`, `yq`, `jq`, `curl`, `openssl` |

## How to run

The K8s-native bring-up is the parent [`scripts/aws-setup/up.sh`](../up.sh) — it
provisions the EKS cluster + sandbox node pool, S3, IAM, ingress, and TLS, then
`helm install daytona-region ./charts/daytona-region`. The validation scripts in
*this* directory (`e2e.sh`, `teardown.sh`) drive and assert against the region
it stands up.

```bash
cd scripts/aws-setup

export DAYTONA_API_KEY='dtn_paste-organization-key-here'
export DOMAIN='byoc.yourdomain.com'
export ACME_EMAIL='you@yourdomain.com'
export CLOUDFLARE_API_TOKEN='paste-dns-provider-token'

# AWS auth - any one of these
export AWS_PROFILE=my-profile
# OR
# export AWS_ACCESS_KEY_ID='...'
# export AWS_SECRET_ACCESS_KEY='...'
# OR
# aws sso login

# Bring up the region (EKS + sandbox node pool + S3 + IAM + ingress + TLS +
# helm install daytona-region). Re-runnable if interrupted.
./up.sh

# SDK smoke test + assertions (run from this test directory):
cd test
./e2e.sh

# Cleanup (also deregisters the region from Daytona Cloud):
./teardown.sh
```

### Overriding defaults

```bash
# Different AWS region
AWS_DEFAULT_REGION=eu-west-1 ./up.sh

# Use Let's Encrypt staging while iterating (avoids prod LE rate limits)
STAGING=true ./up.sh
```

Sandbox capacity is set by the **sandbox node pool** (instance type × node
count), not by separate VMs — scale the region by changing the node pool.

## Layout

Bring-up lives in the parent directory; this directory holds the validation
and cleanup scripts plus its own values template.

```
aws-setup/
├── up.sh                          # (parent) provision AWS plumbing + helm
│                                  # install daytona-region — see ../README.md.
└── test/
    ├── e2e.sh                     # SDK test: daytona.create(target=region)
    │                              # then code_run("print('Hello World')").
    ├── teardown.sh                # cleanup: deregister region from Daytona
    │                              # Cloud, helm uninstall, eksctl delete,
    │                              # S3 empty+delete, IAM, DNS, local state.
    ├── values-region.yaml.tmpl    # daytona-region helm values (envsubst'd).
    │                              # Wires snapshot-manager AND the runner
    │                              # DaemonSet to the same S3 bucket so the
    │                              # declarative builder works.
    └── .state/                    # generated at runtime (region-id, names,
                                   # IAM keys, rendered manifests). gitignored.
```

## Asserting each stage

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

## Comparison to the Azure harness (`../../azure-setup/test/`)

Both harnesses install the identical `daytona-region` chart — runners are a
DaemonSet inside the managed cluster in both cases. Only the cloud-specific
plumbing differs:

| | AWS (this) | Azure (`../../azure-setup/test/`) |
|---|---|---|
| Cluster | EKS via eksctl | AKS via `az aks create` |
| Runners | DaemonSet pods in your EKS cluster | DaemonSet pods in your AKS cluster |
| Snapshot storage | Native S3 (no shim) | Azure Blob via rclone S3-gateway sidecar |
| Builder S3 endpoint | `https://s3.<region>.amazonaws.com` | `http://rclone-s3-gateway.daytona-region:8080` |
| LB | NLB (via ingress-nginx annotation) | Azure LB (via ingress-nginx default) |
| DNS records | CNAME (NLB has a hostname) | A (LB has an IP) |

The AWS path is *simpler* (S3 is native, no rclone shim; IAM/IRSA maps cleanly
onto EKS service accounts) but *more involved* in resource count (EKS creates a
VPC, subnets, NAT GW, IGW, route tables, SGs, cluster IAM roles, and an OIDC
provider — more to track and tear down).

## Known gaps

- **Static IAM keys by default.** Uses an IAM user's keys for both the
  snapshot-manager and the runner. Production should use IRSA on the
  snapshot-manager and runner ServiceAccounts
  (`services.runner.aws.credentialMode: irsa`). The chart supports this — see
  [`charts/daytona-region/README.md`](../../../charts/daytona-region/README.md)
  and [`docs/issues-summary.md`](../../../docs/issues-summary.md).
- **Single sandbox node pool, public subnets.** One node group in public
  subnets. Real fleets want sandbox nodes across multiple AZs and private
  subnets with tightened security groups.
- **No node-pool autoscaler.** The sandbox node pool is fixed-size. Production
  pairs the DaemonSet with the Cluster Autoscaler or Karpenter so new sandbox
  nodes — and therefore new runner pods — appear under load.

## When the run is green

You will have:
1. A working BYOC region on EKS with the runner DaemonSet scheduled onto the
   sandbox node pool — runners run inside the cluster, not on separate VMs.
2. Working SDK calls targeting the custom region.
3. Working declarative-builder snapshot creation (runner `AWS_*` env vars point
   at the same S3 bucket the snapshot-manager uses).
4. Coverage of each gotcha listed above.

Tear down with `teardown.sh`, or re-run `up.sh` (idempotent) to iterate.
