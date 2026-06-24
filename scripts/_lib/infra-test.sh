#!/usr/bin/env bash
# scripts/_lib/infra-test.sh — live-cluster infra test helpers.
# Sourced by scripts/<setup>/test/infra/*.sh after sourcing common.sh.
#
# These helpers query Postgres, the daytona api, and Kubernetes to make hard
# binary assertions about a live cluster. They are the runtime complement to
# the static checks under scripts/_lib/check/.
#
# Column names match upstream daytonaio/daytona apps/api/src/sandbox/entities/runner.entity.ts:
#   id, domain, apiUrl, proxyUrl, apiKey, cpu, memoryGiB, diskGiB, gpu, gpuType,
#   sandboxClass, runnerClass, availabilityScore, region, name, state, appVersion,
#   apiVersion, lastChecked, unschedulable, draining, tags, serviceHealth.
#
# Conventions:
#   * All functions namespaced omc::infra::* to avoid collisions with common.sh.
#   * Caller must have already run common.sh (provides omc::log, omc::die, etc.).
#   * Caller must have a working KUBECONFIG pointing at the cluster.
#   * Caller must have sourced the matching .state/oss-secrets.env (provides
#     POSTGRES_PASSWORD) before calling DB helpers.

# ---------------------------------------------------------------- kube basics
omc::infra::get_pod() {
  local ns="$1" selector="$2"
  kubectl -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

omc::infra::wait_for_pods_ready() {
  local ns="$1" selector="$2" timeout="${3:-300}"
  omc::log INFO "Waiting up to ${timeout}s for pods (-l $selector) in $ns to be Ready..."
  if kubectl -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout="${timeout}s" >/dev/null 2>&1; then
    omc::log INFO "Pods (-l $selector) Ready"
    return 0
  fi
  omc::log ERROR "Timed out waiting for pods -l $selector in $ns"
  kubectl -n "$ns" get pod -l "$selector"
  return 1
}

omc::infra::get_sandbox_nodes() {
  kubectl get nodes -l daytona-sandbox-c=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# ---------------------------------------------------------------- postgres helpers
omc::infra::psql() {
  local ns="$1" query="$2"
  local pg_pod
  pg_pod="$(omc::infra::get_pod "$ns" "app.kubernetes.io/name=postgresql")"
  if [[ -z "$pg_pod" ]]; then
    omc::die "psql: postgres pod not found in namespace $ns"
  fi
  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    omc::die "psql: POSTGRES_PASSWORD env not set; source .state/oss-secrets.env first"
  fi
  # POSTGRES_PASSWORD is the SUPERUSER password (postgresql.auth.postgresPassword);
  # the bitnami app user ("user") has a separate password, so connect as postgres.
  kubectl -n "$ns" exec "$pg_pod" -- env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U postgres -d daytona -t -A -c "$query" 2>/dev/null
}

omc::infra::query_runners_table() {
  local ns="$1"
  local pg_pod
  pg_pod="$(omc::infra::get_pod "$ns" "app.kubernetes.io/name=postgresql")"
  if [[ -z "$pg_pod" ]]; then
    omc::die "query_runners_table: postgres pod not found in $ns"
  fi
  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    omc::die "query_runners_table: POSTGRES_PASSWORD not set"
  fi
  kubectl -n "$ns" exec "$pg_pod" -- env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U postgres -d daytona -c \
    'SELECT id, name, region, state, "apiKey", "availabilityScore", cpu, "memoryGiB", "diskGiB", "lastChecked", "apiVersion", unschedulable, draining FROM runner ORDER BY "createdAt";' 2>&1
}

omc::infra::count_ready_runners() {
  local ns="$1" region="${2:-us}"
  local count
  count="$(omc::infra::psql "$ns" \
    "SELECT COUNT(*) FROM runner WHERE state='ready' AND region='${region}' AND unschedulable IS NOT TRUE AND draining IS NOT TRUE;" 2>/dev/null | tr -d '[:space:]')"
  echo "${count:-0}"
}

omc::infra::wait_runner_ready() {
  local ns="$1" region="${2:-us}" timeout="${3:-180}"
  omc::log INFO "Waiting up to ${timeout}s for at least one runner state=ready in region=${region}..."
  local elapsed=0 sleep_sec=10 count
  while [[ $elapsed -lt $timeout ]]; do
    count="$(omc::infra::count_ready_runners "$ns" "$region")"
    if [[ "$count" -ge 1 ]]; then
      omc::log INFO "$count runner(s) READY in region=${region}"
      return 0
    fi
    sleep $sleep_sec
    elapsed=$((elapsed + sleep_sec))
  done
  omc::log ERROR "No READY runners after ${timeout}s in region=${region}. Dumping runner table:"
  omc::infra::query_runners_table "$ns" || true
  return 1
}

# ---------------------------------------------------------------- cert-manager helpers
omc::infra::wait_certificate_ready() {
  local ns="$1" cert_name="$2" timeout="${3:-300}"
  omc::log INFO "Waiting up to ${timeout}s for Certificate $ns/$cert_name to be Ready..."
  if kubectl -n "$ns" wait --for=condition=Ready "certificate/$cert_name" --timeout="${timeout}s" >/dev/null 2>&1; then
    omc::log INFO "Certificate $cert_name Ready"
    return 0
  fi
  omc::log ERROR "Certificate $cert_name not Ready after ${timeout}s"
  kubectl -n "$ns" describe certificate "$cert_name" | tail -30
  return 1
}

omc::infra::probe_serving_cert_issuer() {
  local hostname="$1" port="${2:-443}"
  echo | openssl s_client -showcerts -servername "$hostname" -connect "${hostname}:${port}" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null \
    | sed 's/^issuer=//'
}

omc::infra::assert_cert_is_real() {
  local hostname="$1"
  local issuer
  issuer="$(omc::infra::probe_serving_cert_issuer "$hostname")"
  if [[ -z "$issuer" ]]; then
    omc::die "Could not probe TLS cert at $hostname (no response or openssl failed)"
  fi
  if echo "$issuer" | grep -qiE "fake certificate|kubernetes ingress controller"; then
    omc::log ERROR "Cert at $hostname is the nginx-ingress FAKE cert (cert-manager has not issued real cert)"
    omc::log ERROR "  issuer: $issuer"
    return 1
  fi
  omc::log INFO "Cert at $hostname looks real: $issuer"
  return 0
}

# ---------------------------------------------------------------- api env helpers
omc::infra::api_env_var() {
  local ns="$1" var="$2"
  kubectl -n "$ns" exec deploy/daytona-api -- printenv "$var" 2>/dev/null || echo ""
}

omc::infra::runner_env_var() {
  local ns="$1" var="$2"
  local pod
  pod="$(omc::infra::get_pod "$ns" "app.kubernetes.io/component=runner")"
  if [[ -z "$pod" ]]; then
    return 1
  fi
  kubectl -n "$ns" exec "$pod" -c runner -- printenv "$var" 2>/dev/null || echo ""
}

omc::infra::assert_token_match() {
  local ns="$1"
  local api_token runner_token
  api_token="$(omc::infra::api_env_var "$ns" DEFAULT_RUNNER_API_KEY)"
  runner_token="$(omc::infra::runner_env_var "$ns" API_TOKEN)"
  if [[ -z "$api_token" || -z "$runner_token" ]]; then
    omc::log ERROR "Token check: api DEFAULT_RUNNER_API_KEY=[${api_token}] runner API_TOKEN=[${runner_token}]"
    return 1
  fi
  if [[ "$api_token" != "$runner_token" ]]; then
    omc::log ERROR "Token MISMATCH: api='$api_token' runner='$runner_token'"
    return 1
  fi
  omc::log INFO "api DEFAULT_RUNNER_API_KEY == runner API_TOKEN ($api_token)"
  return 0
}

# ---------------------------------------------------------------- aks helpers
omc::infra::aks_mc_rg() {
  local rg="$1" cluster="$2" location="$3"
  echo "MC_${rg}_${cluster}_${location}"
}

omc::infra::aks_delete_node() {
  local cluster="$1" rg="$2" nodepool="$3" node="$4"
  omc::log INFO "Cordoning + draining $node..."
  kubectl cordon "$node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>/dev/null || true
  omc::log INFO "Asking AKS to delete machine $node..."
  if az aks nodepool delete-machines \
       --cluster-name "$cluster" \
       --resource-group "$rg" \
       --nodepool-name "$nodepool" \
       --machine-names "$node" >/dev/null 2>&1; then
    omc::log INFO "delete-machines succeeded for $node"
    return 0
  fi
  omc::log WARN "az aks nodepool delete-machines failed (CLI too old?); falling back to az vmss delete-instances"
  local instance_id="${node##*vmss}"
  local vmss_name="${node%vmss*}vmss"
  local location
  location="$(az aks show --name "$cluster" --resource-group "$rg" --query location -o tsv)"
  local mc_rg
  mc_rg="$(omc::infra::aks_mc_rg "$rg" "$cluster" "$location")"
  az vmss delete-instances \
    --resource-group "$mc_rg" \
    --name "$vmss_name" \
    --instance-ids "$instance_id" >/dev/null \
    || omc::die "Both delete-machines and vmss delete-instances failed for $node"
  omc::log INFO "vmss delete-instances succeeded for $node"
}

omc::infra::wait_new_sandbox_node() {
  local known_nodes="$1" timeout="${2:-600}"
  omc::log INFO "Waiting up to ${timeout}s for a NEW sandbox node (not in: $(echo "$known_nodes" | tr '\n' ' '))..."
  local elapsed=0 sleep_sec=15 current new_node
  while [[ $elapsed -lt $timeout ]]; do
    current="$(omc::infra::get_sandbox_nodes)"
    new_node="$(comm -23 <(echo "$current" | sort) <(echo "$known_nodes" | sort) | head -1)"
    if [[ -n "$new_node" ]]; then
      omc::log INFO "New sandbox node: $new_node"
      printf '%s' "$new_node"
      return 0
    fi
    sleep $sleep_sec
    elapsed=$((elapsed + sleep_sec))
  done
  omc::log ERROR "Timed out waiting for a new sandbox node"
  return 1
}
