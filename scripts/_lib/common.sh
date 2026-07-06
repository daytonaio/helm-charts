#!/usr/bin/env bash
# scripts/_lib/common.sh — shared helpers for BYOC e2e setup scripts.
# Sourced by scripts/{aws,azure,gcs}-setup/up.sh and teardown.sh.
#
# Conventions:
#   * Functions are namespaced with omc:: prefix to avoid collisions.
#   * All functions assume `set -euo pipefail` is set in the caller; do NOT
#     re-enable it here (lets the caller decide).
#   * Logging goes to STDERR so stdout can carry structured data (URLs, paths).
#   * Honor OMC_NONINTERACTIVE=1 (use defaults or fail) and OMC_YES=1 (skip
#     confirmation prompts).

# ---------------------------------------------------------------- logging
omc::log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >&2
}

omc::die() {
  omc::log ERROR "$*"
  exit 1
}

# ---------------------------------------------------------------- prereqs
omc::need_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    omc::die "Missing required commands: ${missing[*]}. Install them before running this script."
  fi
}

# ---------------------------------------------------------------- prompts
# omc::prompt_choice VAR "label" CHOICE1 [CHOICE2 ...]
# Prompts the operator to pick one of the listed choices by number. First choice
# is the default. Pre-set values (e.g. TLS_MODE=cloudflare-dns01 in env) are
# honored if they match one of the choices; otherwise the prompt rejects and
# re-asks. In OMC_NONINTERACTIVE mode, uses the first choice as default.
omc::prompt_choice() {
  local var="$1" label="$2"; shift 2
  local choices=("$@")
  local default="${choices[0]}"
  if [[ -n "${!var:-}" ]]; then
    local found=0
    for c in "${choices[@]}"; do
      if [[ "$c" == "${!var}" ]]; then found=1; break; fi
    done
    if [[ "$found" -eq 1 ]]; then
      omc::log INFO "$var (pre-set): ${!var}"
      return 0
    fi
    omc::log WARN "$var pre-set to '${!var}' but not in allowed choices (${choices[*]}); re-prompting"
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    printf -v "$var" '%s' "$default"
    export "${var?}"
    omc::log INFO "$var (default, non-interactive): $default"
    return 0
  fi
  echo "$label" >&2
  local i=1
  for c in "${choices[@]}"; do
    echo "  $i) $c" >&2
    i=$((i+1))
  done
  local reply
  while true; do
    read -r -p "Choose 1-${#choices[@]} [1=$default]: " reply
    reply="${reply:-1}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#choices[@]} )); then
      printf -v "$var" '%s' "${choices[$((reply-1))]}"
      export "${var?}"
      omc::log INFO "$var = ${!var}"
      return 0
    fi
    echo "  Invalid choice; pick a number 1-${#choices[@]}" >&2
  done
}

# omc::prompt VAR "label" [default]
# Reads a value into VAR. If OMC_NONINTERACTIVE=1, uses default or dies.
omc::prompt() {
  local var="$1" label="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then
    omc::log INFO "$var (pre-set): ${!var}"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var" '%s' "$default"
      export "${var?}"
      omc::log INFO "$var (default, non-interactive): $default"
      return 0
    fi
    omc::die "$var has no value and no default; cannot prompt in non-interactive mode."
  fi
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
    while [[ -z "$value" ]]; do
      omc::log WARN "$var cannot be empty"
      read -r -p "$label: " value
    done
  fi
  printf -v "$var" '%s' "$value"
  export "${var?}"
}

# omc::prompt_secret VAR "label" — no echo, no default.
omc::prompt_secret() {
  local var="$1" label="$2"
  if [[ -n "${!var:-}" ]]; then
    omc::log INFO "$var (pre-set, masked)"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    omc::die "$var is a secret and has no value; cannot prompt in non-interactive mode."
  fi
  local value
  read -r -s -p "$label: " value
  printf '\n' >&2
  if [[ -z "$value" ]]; then
    omc::die "$var cannot be empty"
  fi
  printf -v "$var" '%s' "$value"
  export "${var?}"
}

# omc::confirm "label" — y/N (default N). OMC_YES=1 auto-yes.
omc::confirm() {
  local label="$1"
  if [[ "${OMC_YES:-0}" == "1" ]]; then
    omc::log INFO "AUTO-YES: $label"
    return 0
  fi
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    omc::die "Confirmation prompt blocked in non-interactive mode: $label"
  fi
  local reply
  read -r -p "$label (y/N): " reply
  if [[ "$reply" =~ ^[Yy] ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- templating
# omc::render_template src.tmpl dst.yaml
# envsubst wrapper that fails on UNRESOLVED ${...} placeholders.
# Rendered output is chmod'd 0600 because it embeds secrets (DAYTONA_API_KEY,
# IAM_SECRET_KEY, HMAC_SECRET_KEY, RCLONE_SECRET_KEY) lifted from the
# matching .state/*.env files.
omc::render_template() {
  local src="$1" dst="$2"
  if [[ ! -f "$src" ]]; then
    omc::die "render_template: source missing: $src"
  fi
  envsubst < "$src" > "$dst"
  chmod 600 "$dst"
  local unresolved
  unresolved="$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$dst" || true)"
  if [[ -n "$unresolved" ]]; then
    omc::log ERROR "render_template: unresolved placeholders in $dst:"
    printf '%s\n' "$unresolved" >&2
    omc::die "set the missing vars before re-running"
  fi
  omc::log INFO "rendered $src -> $dst ($(wc -l < "$dst") lines, mode 0600)"
}

# ---------------------------------------------------------------- state
# omc::state_dir SCRIPT_DIR — returns "$SCRIPT_DIR/.state", mkdir -p.
omc::state_dir() {
  local script_dir="$1"
  local dir="$script_dir/.state"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------- kube helpers
# omc::wait_lb_address NS SVC [timeout_sec=300]
# Polls the Service's LoadBalancer ingress[0].ip OR hostname, prints whichever non-empty.
omc::wait_lb_address() {
  local ns="$1" svc="$2" timeout="${3:-300}"
  omc::log INFO "Waiting up to ${timeout}s for LoadBalancer address on $ns/$svc..."
  local elapsed=0 sleep_sec=5
  local ip hostname
  while [[ $elapsed -lt $timeout ]]; do
    ip="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    hostname="$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    if [[ -n "$hostname" ]]; then
      printf '%s' "$hostname"
      return 0
    fi
    sleep $sleep_sec
    elapsed=$((elapsed + sleep_sec))
  done
  omc::die "Timed out waiting for LoadBalancer address on $ns/$svc"
}

# omc::print_dns_records BASE_DOMAIN LB_TARGET
# Prints the 3 DNS records the operator must create.
omc::print_dns_records() {
  local base="$1" target="$2"
  local rec_type="A"
  if [[ "$target" == *.* && ! "$target" =~ ^[0-9.]+$ ]]; then
    rec_type="CNAME"
  fi
  cat >&2 <<EOF

==================== DNS RECORDS TO CREATE ====================
The Daytona BYOC region needs these DNS records pointing at the
ingress LoadBalancer ($target):

  proxy.${base}        $rec_type   $target
  *.proxy.${base}      $rec_type   $target     (wildcard for sandbox subdomains)
  snapshots.${base}    $rec_type   $target

Create them in your DNS provider (Route53/Azure DNS/Cloud DNS/...) NOW.
Wait for propagation (usually 30-300s) before continuing.
===============================================================

EOF
}

# omc::cloudflare_upsert_dns TOKEN ZONE_ID NAME TYPE CONTENT
# Create-or-update one DNS record (DNS-only / grey-cloud). Idempotent.
omc::cloudflare_upsert_dns() {
  local token="$1" zone_id="$2" name="$3" type="$4" content="$5"
  local api="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
  local rec_id body resp ok
  rec_id="$(curl -sS -H "Authorization: Bearer $token" "${api}?type=${type}&name=${name}" \
    | jq -r '.result[0].id // empty')"
  body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
    '{type:$t,name:$n,content:$c,ttl:120,proxied:false}')"
  if [[ -n "$rec_id" ]]; then
    resp="$(curl -sS -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body" "${api}/${rec_id}")"
  else
    resp="$(curl -sS -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body" "${api}")"
  fi
  ok="$(printf '%s' "$resp" | jq -r '.success')"
  if [[ "$ok" == "true" ]]; then
    omc::log INFO "  Cloudflare ${type} ${name} -> ${content} (DNS-only)"
  else
    omc::log WARN "  Cloudflare ${type} ${name} FAILED: $(printf '%s' "$resp" | jq -c '.errors')"
    return 1
  fi
}

# omc::cloudflare_region_dns TOKEN BASE_DOMAIN LB_TARGET
# Upsert the region's routing records (proxy, *.proxy, snapshots) -> the ingress
# LoadBalancer. CNAME for an AWS NLB hostname, A for an IP. ALL DNS-only: the
# proxy carries long websockets + large uploads and the wildcard preview certs
# come from cert-manager — neither survives Cloudflare's HTTP proxy. Assumes the
# Cloudflare zone IS the base domain.
omc::cloudflare_region_dns() {
  local token="$1" base="$2" target="$3"
  local zone_id rtype=CNAME
  zone_id="$(curl -sS -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=${base}" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || omc::die "Cloudflare zone '${base}' not found (token lacks access or zone name differs)."
  [[ "$target" =~ ^[0-9.]+$ ]] && rtype=A
  omc::log INFO "Upserting Cloudflare DNS in zone ${base} (${rtype} -> ${target})..."
  omc::cloudflare_upsert_dns "$token" "$zone_id" "proxy.${base}"     "$rtype" "$target"
  omc::cloudflare_upsert_dns "$token" "$zone_id" "*.proxy.${base}"   "$rtype" "$target"
  omc::cloudflare_upsert_dns "$token" "$zone_id" "snapshots.${base}" "$rtype" "$target"
}

# ---------------------------------------------------------------- helm helpers
# omc::ingress_nginx_install [namespace=ingress-nginx]
# Critical: pass TCP probe annotations on the LB Service. Azure Standard LB defaults
# its health probe to HTTP / against the NodePort. ingress-nginx returns 404 for /,
# Standard LB treats !=200 as unhealthy, marks ALL backends down, and SILENTLY drops
# inbound packets at the network layer (real SYN timeout, not HTTP error). TCP probes
# bypass the HTTP semantic entirely and validate the port is open. See:
# https://kubernetes.io/docs/concepts/services-networking/cloud-providers/#load-balancer
omc::ingress_nginx_install() {
  local ns="${1:-ingress-nginx}"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  # A prior failed/pending install blocks re-install ("another operation in
  # progress"); clear any non-deployed release first so re-runs are reliable.
  local st
  st="$(helm status ingress-nginx -n "$ns" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || true)"
  if [[ -n "$st" && "$st" != "deployed" ]]; then
    omc::log WARN "ingress-nginx release is '$st' (prior failed install) — uninstalling before reinstall."
    helm uninstall ingress-nginx -n "$ns" >/dev/null 2>&1 || true
  fi
  # The cluster's only node group is the sandbox pool, tainted
  # sandbox=true:NoSchedule (reserved for the daytona-region runner DaemonSet).
  # Platform add-ons must tolerate it or they sit Pending — the admission-webhook
  # Job never completes and helm --wait dies with "context deadline exceeded".
  # Tolerate it on the controller AND the admission patch Jobs.
  local tol; tol="$(mktemp)"
  cat > "$tol" <<'EOF'
controller:
  tolerations:
    - key: sandbox
      operator: Equal
      value: "true"
      effect: NoSchedule
  admissionWebhooks:
    patch:
      tolerations:
        - key: sandbox
          operator: Equal
          value: "true"
          effect: NoSchedule
EOF
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n "$ns" --create-namespace \
    --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/port_80_health-probe_protocol=tcp" \
    --set-string "controller.service.annotations.service\.beta\.kubernetes\.io/port_443_health-probe_protocol=tcp" \
    -f "$tol" \
    --wait --timeout 5m \
    || { rm -f "$tol"; omc::die "ingress-nginx install failed"; }
  rm -f "$tol"
  omc::log INFO "ingress-nginx ready in $ns (TCP probes on 80/443)"
}

# omc::cert_manager_install [namespace=cert-manager]
omc::cert_manager_install() {
  local ns="${1:-cert-manager}"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  local st
  st="$(helm status cert-manager -n "$ns" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || true)"
  if [[ -n "$st" && "$st" != "deployed" ]]; then
    omc::log WARN "cert-manager release is '$st' (prior failed install) — uninstalling before reinstall."
    helm uninstall cert-manager -n "$ns" >/dev/null 2>&1 || true
  fi
  # Same single-tainted-node-pool constraint as ingress-nginx: tolerate the
  # sandbox taint on the controller, webhook, cainjector AND the startupapicheck
  # Job (which helm --wait blocks on).
  local tol; tol="$(mktemp)"
  cat > "$tol" <<'EOF'
tolerations:
  - key: sandbox
    operator: Equal
    value: "true"
    effect: NoSchedule
webhook:
  tolerations:
    - key: sandbox
      operator: Equal
      value: "true"
      effect: NoSchedule
cainjector:
  tolerations:
    - key: sandbox
      operator: Equal
      value: "true"
      effect: NoSchedule
startupapicheck:
  tolerations:
    - key: sandbox
      operator: Equal
      value: "true"
      effect: NoSchedule
EOF
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n "$ns" --create-namespace \
    --set crds.enabled=true \
    -f "$tol" \
    --wait --timeout 5m \
    || { rm -f "$tol"; omc::die "cert-manager install failed"; }
  rm -f "$tol"
  omc::log INFO "cert-manager ready in $ns"
}

# omc::coredns_tolerate_taint [key=sandbox] [value=true] [effect=NoSchedule]
# The only node pool is tainted sandbox=true:NoSchedule, but CoreDNS (a
# kube-system Deployment) ships without that toleration — so it sits Pending and
# the cluster has NO DNS. In-cluster calls then fail to resolve (e.g. the region
# registration hook curling app.daytona.io exits non-zero). Add the toleration
# idempotently so DNS comes up before anything that needs it.
omc::coredns_tolerate_taint() {
  local key="${1:-sandbox}" value="${2:-true}" effect="${3:-NoSchedule}"
  if ! kubectl -n kube-system get deploy coredns >/dev/null 2>&1; then
    omc::log WARN "coredns deployment not found in kube-system; skipping DNS toleration patch."
    return 0
  fi
  if kubectl -n kube-system get deploy coredns \
       -o jsonpath='{.spec.template.spec.tolerations[*].key}' 2>/dev/null \
       | tr ' ' '\n' | grep -qx "$key"; then
    omc::log INFO "coredns already tolerates ${key}=${value}:${effect}."
    return 0
  fi
  omc::log INFO "Patching coredns to tolerate ${key}=${value}:${effect} (single tainted node pool)..."
  kubectl -n kube-system patch deploy coredns --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":{\"key\":\"${key}\",\"operator\":\"Equal\",\"value\":\"${value}\",\"effect\":\"${effect}\"}}]" \
    || omc::die "failed to patch coredns tolerations"
  kubectl -n kube-system rollout status deploy coredns --timeout=120s || true
  omc::log INFO "coredns patched; cluster DNS should schedule onto the sandbox node."
}

# omc::cluster_issuer_apply EMAIL
# Applies a Let's Encrypt HTTP-01 ClusterIssuer named letsencrypt-prod.
# Wave 3 placeholder; filled in W3.1.
omc::cluster_issuer_apply() {
  local email="$1"
  if [[ -z "$email" ]]; then
    omc::die "cluster_issuer_apply: email is required"
  fi
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
  omc::log INFO "ClusterIssuer letsencrypt-prod applied (email=${email})"
}

# omc::cluster_issuer_apply_cf_dns01 EMAIL CF_API_TOKEN [ns=cert-manager]
# Applies a Let's Encrypt DNS-01 ClusterIssuer named letsencrypt-prod with a
# Cloudflare solver. REQUIRED for wildcard SANs — HTTP-01 cannot satisfy
# wildcard challenges per Let's Encrypt rules. The daytona chart's api/proxy
# ingresses emit wildcard TLS specs (*.<baseDomain>), so DNS-01 is the only
# challenge type that yields valid certs for those ingresses.
#
# CF_API_TOKEN must have these zone-scoped permissions for BASE_DOMAIN's zone:
#   Zone:Read, Zone DNS:Edit
# Create at: Cloudflare dashboard → My Profile → API Tokens → Create Token →
# "Edit zone DNS" template.
omc::cluster_issuer_apply_cf_dns01() {
  local email="$1" cf_token="$2" ns="${3:-cert-manager}"
  if [[ -z "$email" || -z "$cf_token" ]]; then
    omc::die "cluster_issuer_apply_cf_dns01: email and cf_token are required"
  fi

  kubectl -n "$ns" create secret generic cloudflare-api-token \
    --from-literal=api-token="$cf_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
  omc::log INFO "ClusterIssuer letsencrypt-prod applied (DNS-01 via Cloudflare; email=${email})"
}

# omc::certs_preissue BASE_DOMAIN [ns=daytona] [issuer=letsencrypt-prod]
# Pre-creates the three Certificates the daytona chart's ingresses reference
# (api+harbor -> <base>-tls, dex -> dex.<base>-tls, proxy -> proxy.<base>-tls)
# so ACME issuance starts BEFORE helm install instead of when ingress-shim
# first sees the ingresses. Without this the api pushes the default snapshot
# to harbor.<base> seconds after boot while DNS-01 issuance is still in
# flight; ingress-nginx serves its built-in fake cert (SAN ingress.local) and
# the snapshot lands in terminal state=error ("x509: certificate is valid for
# ingress.local, not harbor.<base>"). DNS-01 needs no A/CNAME records, only
# the Cloudflare API, so this can run as soon as the ClusterIssuer exists.
# dnsNames mirror the chart's ingress tls blocks exactly, so ingress-shim
# later finds spec-identical Certificates and leaves them alone.
omc::certs_preissue() {
  local base="$1" ns="${2:-daytona}" issuer="${3:-letsencrypt-prod}"
  if [[ -z "$base" ]]; then
    omc::die "certs_preissue: base domain is required"
  fi
  kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${base}-tls
  namespace: ${ns}
spec:
  secretName: ${base}-tls
  issuerRef:
    name: ${issuer}
    kind: ClusterIssuer
  dnsNames:
    - "${base}"
    - "*.${base}"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dex.${base}-tls
  namespace: ${ns}
spec:
  secretName: dex.${base}-tls
  issuerRef:
    name: ${issuer}
    kind: ClusterIssuer
  dnsNames:
    - "dex.${base}"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: proxy.${base}-tls
  namespace: ${ns}
spec:
  secretName: proxy.${base}-tls
  issuerRef:
    name: ${issuer}
    kind: ClusterIssuer
  dnsNames:
    - "*.${base}"
    - "${base}"
EOF
  omc::log INFO "Certificates pre-issued in ns ${ns}: ${base}-tls, dex.${base}-tls, proxy.${base}-tls (issuer=${issuer})"
}

# omc::certs_wait_ready [ns=daytona] [timeout=20m]
# Blocks until every cert-manager Certificate in the namespace is Ready.
# ACME DNS-01 (order -> TXT record -> propagation self-check -> issuance)
# routinely takes 5-20 min; installing the chart before this returns re-opens
# the fake-cert window that certs_preissue exists to close.
omc::certs_wait_ready() {
  local ns="${1:-daytona}" timeout="${2:-20m}"
  omc::log INFO "Waiting up to ${timeout} for Certificates in ns ${ns} to be Ready..."
  kubectl wait --for=condition=Ready certificate --all -n "$ns" --timeout="$timeout" >/dev/null \
    || omc::die "Certificates not Ready after ${timeout}; debug: kubectl describe certificate -n ${ns} && kubectl logs -n cert-manager deploy/cert-manager"
  omc::log INFO "All Certificates Ready in ns ${ns}"
}

# omc::az_register_providers PROVIDER1 PROVIDER2 ...
# Checks each Azure resource provider's registrationState; for any not "Registered",
# prompts to register (with --wait). NEW Azure subscriptions ship with no providers
# registered, so `az aks create` fails with MissingSubscriptionRegistration. This
# is a one-time-per-subscription setup; subsequent up.sh re-runs are no-ops.
omc::az_register_providers() {
  local missing=()
  local ns state
  for ns in "$@"; do
    state="$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    if [[ "$state" != "Registered" ]]; then
      omc::log INFO "Azure provider $ns: ${state:-Unknown} (needs registration)"
      missing+=("$ns")
    else
      omc::log INFO "Azure provider $ns: Registered"
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  omc::log WARN ""
  omc::log WARN "Azure subscription needs ${#missing[@]} resource provider(s) registered:"
  omc::log WARN "  ${missing[*]}"
  omc::log WARN "Registration takes 2-5 min per provider and is a one-time per-subscription setup."
  omc::log WARN ""
  if ! omc::confirm "Register the missing providers now? (No = abort + run manually)"; then
    omc::log ERROR "Aborted. Run manually before re-running this script:"
    local p
    for p in "${missing[@]}"; do
      omc::log ERROR "  az provider register --namespace $p --wait"
    done
    omc::die "Provider registration required."
  fi

  for ns in "${missing[@]}"; do
    omc::log INFO "Registering $ns (may take 2-5 min)..."
    az provider register --namespace "$ns" --wait
    omc::log INFO "$ns Registered"
  done
}

# omc::verify_node_ubuntu [required_version=24.04] [label_selector=daytona-sandbox-c=true] [timeout=300]
# Fails-fast if any node matching the selector is NOT running the required Ubuntu version.
# Pass an empty selector ("") to verify every node in the cluster.
# The Daytona helm chart's docker-installer downloads Ubuntu 24.04 (noble) .deb
# packages directly — running on Ubuntu 22.04 (jammy) or any other distro WILL
# fail when the runner attempts to bootstrap Docker on the node.
# This function is the gatekeeper that catches this BEFORE helm install starts,
# so the operator sees a clear error instead of a cryptic docker-installer crash.
# NO EXCEPTIONS — operator override is intentionally not provided.
omc::verify_node_ubuntu() {
  local required_version="${1:-24.04}"
  local label_selector="${2-daytona-sandbox-c=true}"
  local timeout="${3:-300}"
  local selector_desc="${label_selector:-<all nodes>}"

  omc::log INFO "Verifying nodes are running Ubuntu $required_version (selector: $selector_desc)..."

  local elapsed=0 node_count=0
  while [[ $elapsed -lt $timeout ]]; do
    if [[ -n "$label_selector" ]]; then
      node_count="$(kubectl get nodes -l "$label_selector" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
    else
      node_count="$(kubectl get nodes \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
    fi
    if [[ "$node_count" -gt 0 ]]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "$node_count" -eq 0 ]]; then
    omc::die "verify_node_ubuntu: no nodes match selector '$selector_desc' after ${timeout}s"
  fi

  local nodes_os
  if [[ -n "$label_selector" ]]; then
    nodes_os="$(kubectl get nodes -l "$label_selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}')"
  else
    nodes_os="$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}')"
  fi

  local bad_nodes="" good_count=0
  while IFS=$'\t' read -r name osimage; do
    [[ -z "$name" ]] && continue
    if [[ "$osimage" == *"Ubuntu $required_version"* ]]; then
      good_count=$((good_count + 1))
      omc::log INFO "  $name -> $osimage [OK]"
    else
      bad_nodes+="  $name -> $osimage"$'\n'
    fi
  done <<< "$nodes_os"

  if [[ -n "$bad_nodes" ]]; then
    omc::log ERROR ""
    omc::log ERROR "==================== UBUNTU VERSION MISMATCH ===================="
    omc::log ERROR "The following nodes are NOT running Ubuntu $required_version:"
    printf '%s' "$bad_nodes" >&2
    omc::log ERROR ""
    omc::log ERROR "The Daytona helm chart's docker-installer downloads Ubuntu 24.04"
    omc::log ERROR "(noble) .deb packages directly. Running on any other Ubuntu version"
    omc::log ERROR "WILL fail when the runner tries to bootstrap Docker."
    omc::log ERROR ""
    omc::log ERROR "Options:"
    omc::log ERROR "  1. Run teardown.sh, then re-run up.sh (it requests Ubuntu 24.04 explicitly)"
    omc::log ERROR "  2. Try a different cloud region where Ubuntu 24.04 is GA"
    omc::log ERROR "  3. Upgrade your cloud CLI (eksctl/az/gcloud) to a version supporting Ubuntu 24.04"
    omc::log ERROR "================================================================="
    omc::die "Refusing to continue. Ubuntu 24.04 is REQUIRED with NO EXCEPTIONS."
  fi

  omc::log INFO "All $good_count node(s) verified running Ubuntu $required_version"
}

# omc::helm_install_wait RELEASE CHART_PATH NS VALUES_FILE [timeout=10m]
omc::helm_install_wait() {
  local release="$1" chart="$2" ns="$3" values="$4" timeout="${5:-10m}"
  # A prior failed/pending install (e.g. a pre-install hook that errored) leaves
  # the release in a non-deployed state that blocks `helm upgrade --install`
  # ("has no deployed releases" / "another operation in progress"). Clear it so
  # a re-run reuses the already-provisioned cluster/IAM/bucket instead of needing
  # a teardown. Real (deployed) releases are upgraded in place, untouched.
  local st
  st="$(helm status "$release" -n "$ns" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || true)"
  if [[ -n "$st" && "$st" != "deployed" ]]; then
    omc::log WARN "$release release is '$st' (prior failed install) — uninstalling before reinstall."
    helm uninstall "$release" -n "$ns" >/dev/null 2>&1 || true
  fi
  if helm upgrade --install "$release" "$chart" \
    -n "$ns" --create-namespace \
    -f "$values" \
    --wait --timeout "$timeout"; then
    omc::log INFO "$release deployed in $ns"
    return 0
  fi
  # Install failed. Surface logs of any non-Running/Completed pods (e.g. a failed
  # pre-install hook like region-registration) BEFORE the Job's
  # ttlSecondsAfterFinished deletes them — otherwise the only signal is helm's
  # opaque "Job Failed" and the real reason (HTTP status/body) is unreachable.
  omc::log ERROR "helm install of $release failed — diagnostics from namespace $ns:"
  kubectl get pods,jobs -n "$ns" 2>/dev/null >&2 || true
  local p
  for p in $(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3!="Running"{print $1}'); do
    printf '----- logs %s/%s -----\n' "$ns" "$p" >&2
    kubectl logs -n "$ns" "$p" --tail=80 --all-containers --prefix 2>&1 | tail -80 >&2 || true
  done
  # Events survive even when Helm has already deleted a failed pre-install hook's
  # pod (Helm 4 cleans up the failed hook before returning), so they are often
  # the only post-mortem signal left. They won't show the HTTP body, though — for
  # that, replicate the registration call (see docs / the GET checks below).
  printf '----- recent events in %s -----\n' "$ns" >&2
  kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null | tail -25 >&2 || true
  omc::die "helm install of $release failed"
}

# ---------------------------------------------------------------- ssh gateway
# omc::ssh_keys_ensure STATE_DIR
# Generates (or reuses, for idempotent re-runs) the SSH keypairs the
# daytona-region chart requires:
#   ssh-client       - keypair the GATEWAY uses to authenticate into sandboxes;
#                      its PUBLIC key must also reach the runners (SSH_PUBLIC_KEY)
#                      or sandboxes refuse gateway connections (silent SSH-only
#                      failure: everything else works).
#   ssh-gateway-host - the gateway's SSH host key.
# Values contract (chart QUICKSTART): values are base64 of the key FILES.
# Exports PRIV_CLIENT_B64 / PUB_CLIENT_B64 / PRIV_GATEWAY_B64 for envsubst.
omc::ssh_keys_ensure() {
  local dir="$1"
  [[ -f "$dir/ssh-client" ]]       || ssh-keygen -t ed25519 -N "" -C client-key   -f "$dir/ssh-client" -q
  [[ -f "$dir/ssh-gateway-host" ]] || ssh-keygen -t ed25519 -N "" -C gateway-host -f "$dir/ssh-gateway-host" -q
  chmod 600 "$dir/ssh-client" "$dir/ssh-gateway-host"
  # macOS base64 has no -w0; strip newlines portably (GNU wraps at 76 cols).
  PRIV_CLIENT_B64="$(base64 < "$dir/ssh-client" | tr -d '\n')"
  PUB_CLIENT_B64="$(base64 < "$dir/ssh-client.pub" | tr -d '\n')"
  PRIV_GATEWAY_B64="$(base64 < "$dir/ssh-gateway-host" | tr -d '\n')"
  export PRIV_CLIENT_B64 PUB_CLIENT_B64 PRIV_GATEWAY_B64
  omc::log INFO "SSH keypairs ready in $dir (ssh-client + ssh-gateway-host)"
}

# omc::region_sshgateway_finalize NS RELEASE CHART_PATH VALUES_FILE API_URL API_KEY
# Post-registration SSH gateway finalization. Must run AFTER helm install (the
# chart's registration hook creates <release>-region-config on install):
#   1. advertise the gateway LoadBalancer to Daytona Cloud (sshGatewayUrl) —
#      regenerate-ssh-gateway-api-key 400s until the region has one, so this
#      must come first;
#   2. fetch the REGION-SCOPED ssh-gateway api key — the org key the values
#      bootstrap with passes boot but 403s on ValidateSshAccess, so SSH
#      sessions would close right after the handshake;
#   3. roll it into the release via a persisted overlay (the gateway has no
#      secret-checksum annotation, so bounce the pod to pick it up).
# Writes the key overlay next to VALUES_FILE; future manual `helm upgrade`
# runs must pass BOTH -f files or the gateway reverts to the org key.
omc::region_sshgateway_finalize() {
  local ns="$1" release="$2" chart="$3" values="$4" api_url="$5" api_key="$6"
  local overlay region_id gw_key gw_addr
  overlay="$(dirname "$values")/values-sshgateway-key.yaml"

  region_id="$(kubectl -n "$ns" get secret "${release}-region-config" -o jsonpath='{.data.id}' 2>/dev/null | base64 -d || true)"
  [[ -n "$region_id" ]] || omc::die "${release}-region-config secret missing — did the registration hook run?"

  # 1. Advertise the gateway LoadBalancer FIRST. regenerate-ssh-gateway-api-key
  #    400s ("Region does not have an SSH gateway URL configured") until the
  #    region carries an sshGatewayUrl, so this PATCH is a prerequisite — not the
  #    finishing touch its position once implied.
  gw_addr="$(omc::wait_lb_address "$ns" "${release}-ssh-gateway" 300 2>/dev/null)" || true
  [[ -n "$gw_addr" ]] || omc::die "ssh-gateway LoadBalancer has no address after 5m — cannot set sshGatewayUrl (the key regeneration below depends on it)"
  curl -sf --retry 4 --retry-all-errors --retry-delay 3 -X PATCH -H "Authorization: Bearer ${api_key}" -H 'Content-Type: application/json' \
    -d "{\"sshGatewayUrl\":\"ssh://${gw_addr}:2222\"}" \
    "${api_url}/regions/${region_id}" >/dev/null \
    || omc::die "could not PATCH sshGatewayUrl ssh://${gw_addr}:2222 for region ${region_id}"
  omc::log INFO "Registered sshGatewayUrl ssh://${gw_addr}:2222 for region ${region_id}"

  # 2. Now that the region has a gateway URL, mint the region-scoped key.
  gw_key="$(curl -sf --retry 4 --retry-all-errors --retry-delay 3 -X POST -H "Authorization: Bearer ${api_key}" \
    "${api_url}/regions/${region_id}/regenerate-ssh-gateway-api-key" | jq -r '.apiKey // empty')"
  [[ -n "$gw_key" ]] || omc::die "could not obtain region-scoped ssh-gateway api key for region ${region_id}"

  # 3. Roll the key into the release; the gateway has no secret-checksum
  #    annotation, so bounce the pod to pick it up.
  {
    printf '# Region-scoped ssh-gateway key (regenerate-ssh-gateway-api-key).\n'
    printf '# Pass this file IN ADDITION to the main values on every helm upgrade.\n'
    printf 'services:\n  sshGateway:\n    apiKey: "%s"\n' "$gw_key"
  } > "$overlay"
  chmod 600 "$overlay"

  helm upgrade "$release" "$chart" -n "$ns" -f "$values" -f "$overlay" \
    --wait --timeout 5m >/dev/null \
    || omc::die "helm upgrade with region ssh-gateway key failed"
  kubectl -n "$ns" delete pod -l app.kubernetes.io/component=ssh-gateway --ignore-not-found >/dev/null 2>&1 || true
  omc::log INFO "ssh-gateway now uses the region-scoped api key (overlay: $overlay)"
}

# ---------------------------------------------------------------- cache
# omc::cache_fresh PATH [ttl_min=15] -> 0 if file exists and is younger than ttl_min minutes.
# BSD/GNU portable via `find -mmin`. macOS bash 3.2 compatible.
omc::cache_fresh() {
  local path="$1" ttl="${2:-15}"
  [[ -f "$path" ]] || return 1
  local fresh
  fresh="$(find "$path" -mmin -"$ttl" -print 2>/dev/null | head -n 1)"
  [[ -n "$fresh" ]]
}

# ---------------------------------------------------------------- menu picker
# omc::pick_from_menu LABEL CHOICES_TSV [override_var]
#
# CHOICES_TSV: newline-separated TSV rows. First row is the header (rendered
# without an index). Subsequent rows are choices; the first column is the
# canonical NAME returned on STDOUT.
#
# Honors:
#   * OMC_NONINTERACTIVE=1   -> pick row 1 silently
#   * ${override_var}        -> skip menu entirely; must match a NAME in body
#                              unless OMC_INSTANCE_TYPE_FORCE=1 (logs WARN)
#
# Output contract:
#   * Menu + log lines    -> STDERR (so callers can capture STDOUT)
#   * Chosen NAME only    -> STDOUT (so `X=$(omc::pick_from_menu ...)` works)
omc::pick_from_menu() {
  local label="$1" tsv="$2" override_var="${3:-}"
  local override=""
  if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
    override="${!override_var}"
  fi
  local header body count
  header="$(printf '%s\n' "$tsv" | head -n 1)"
  body="$(printf '%s\n' "$tsv" | tail -n +2)"
  count="$(printf '%s\n' "$body" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    omc::die "pick_from_menu: no viable choices for '$label'"
  fi
  # Render menu to STDERR
  {
    printf '\n%s\n\n' "$label"
    printf '  #  '
    printf '%s\n' "$header" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-20s", $i; print ""}'
    local i=1 line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '  %d  ' "$i"
      printf '%s\n' "$line" | awk -F'\t' '{for(i=1;i<=NF;i++) printf "%-20s", $i; print ""}'
      i=$((i + 1))
    done <<< "$body"
    printf '\n'
  } >&2
  # Override path (skip interactive)
  if [[ -n "$override" ]]; then
    local found=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$(printf '%s' "$line" | awk -F'\t' '{print $1}')" == "$override" ]]; then
        found="$override"
        break
      fi
    done <<< "$body"
    if [[ -z "$found" ]]; then
      if [[ "${OMC_INSTANCE_TYPE_FORCE:-0}" == "1" ]]; then
        omc::log WARN "Override $override_var=$override not in viable list, forcing anyway (OMC_INSTANCE_TYPE_FORCE=1)"
        printf '%s' "$override"
        return 0
      fi
      omc::die "Override $override_var=$override is NOT in the viable list above. Pick a value from the menu, or set OMC_INSTANCE_TYPE_FORCE=1 to bypass."
    fi
    omc::log INFO "Using $override_var=$override (skipping interactive menu)"
    printf '%s' "$override"
    return 0
  fi
  # Non-interactive: pick row 1
  if [[ "${OMC_NONINTERACTIVE:-0}" == "1" ]]; then
    local first
    first="$(printf '%s\n' "$body" | head -n 1 | awk -F'\t' '{print $1}')"
    omc::log INFO "Non-interactive default: $first"
    printf '%s' "$first"
    return 0
  fi
  # Interactive pick
  local pick=""
  while :; do
    read -r -p "Pick [1-$count, default 1]: " pick
    pick="${pick:-1}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le "$count" ]]; then
      break
    fi
    omc::log WARN "Invalid; enter a number between 1 and $count."
  done
  local chosen
  chosen="$(printf '%s\n' "$body" | awk -v n="$pick" -F'\t' 'NR==n {print $1; exit}')"
  omc::log INFO "Selected: $chosen"
  printf '%s' "$chosen"
}
