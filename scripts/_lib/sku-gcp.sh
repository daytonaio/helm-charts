#!/usr/bin/env bash
# scripts/_lib/sku-gcp.sh — quota-aware GCP GKE machine type selection.
# Sourced by scripts/gcs-setup/up.sh.
#
# Requires: gcloud, jq, awk; STATE_DIR var; sku-data.sh and common.sh sourced first.

# omc::gcp_select_machine_type REGION REQUIRED_VCPU_TOTAL [override_var=OMC_INSTANCE_TYPE]
#
# Picks a GCE machine type that:
#   1. is in the OMC_GCP_FAMILIES allowlist (e2 n2 c3, all x86_64)
#   2. has guestCpus >= 4 per node
#   3. has family-specific quota headroom >= REQUIRED_VCPU_TOTAL
#      - e2  -> CPUS metric (shared with other base families)
#      - n2  -> N2_CPUS metric
#      - c3  -> C3_CPUS metric
#
# REQUIRED_VCPU_TOTAL = vCPU * node_count_per_zone * zone_count for a regional cluster.
# Caller computes this and passes it in (gcs-setup uses vCPU * 6 for 2 nodes/zone * 3 zones).
#
# Outputs the chosen machine type name to STDOUT. Menu + logs go to STDERR.
omc::gcp_select_machine_type() {
  local region="$1" required_vcpu_total="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
  omc::need_cmd gcloud jq awk
  local cache="$STATE_DIR/skus-gcp-$region.json"

  local zones zone_count
  zones="$(gcloud compute regions describe "$region" --format=json 2>/dev/null)" \
    || omc::die "gcloud compute regions describe $region failed (check gcloud auth / project)"
  zone_count="$(jq '.zones | length' <<< "$zones")"
  omc::log INFO "GCP region $region has $zone_count zone(s); regional cluster multiplies node count accordingly."

  local q_e2 q_n2 q_c3
  q_e2="$(jq -r 'first(.quotas[] | select(.metric=="CPUS"))     | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones" 2>/dev/null || echo "0/0")"
  q_n2="$(jq -r 'first(.quotas[] | select(.metric=="N2_CPUS"))  | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones" 2>/dev/null || echo "0/0")"
  q_c3="$(jq -r 'first(.quotas[] | select(.metric=="C3_CPUS"))  | "\(.usage|tostring)/\(.limit|tostring)"' <<< "$zones" 2>/dev/null || echo "0/0")"

  if ! omc::cache_fresh "$cache" 15; then
    local zone_list
    zone_list="$(jq -r '.zones[]' <<< "$zones" | sed 's|.*/||' | tr '\n' ',' | sed 's/,$//')"
    omc::log INFO "Fetching GCE machine types across zones in $region..."
    gcloud compute machine-types list --zones="$zone_list" --format=json > "$cache" \
      || omc::die "gcloud compute machine-types list failed for $region"
  fi

  local viable
  viable="$(jq -r --argjson req "$required_vcpu_total" \
    --arg qe2 "$q_e2" --arg qn2 "$q_n2" --arg qc3 "$q_c3" '
    unique_by(.name) |
    map(. + {family: (.name | split("-") | .[0])}) |
    map(select(.family == "e2" or .family == "n2" or .family == "c3")) |
    map(select(.guestCpus >= 4)) |
    map(. + {rank: (if .family=="c3" then 60 elif .family=="n2" then 50 else 40 end)}) |
    map(. + {quota: (if .family=="c3" then $qc3 elif .family=="n2" then $qn2 else $qe2 end)}) |
    map(. + {
      used:  ((.quota | split("/")[0]) | tonumber? // 0),
      limit: ((.quota | split("/")[1]) | tonumber? // 0)
    }) |
    map(select((.limit - .used) >= $req)) |
    sort_by([-.rank, .guestCpus, .name]) |
    .[0:5] |
    .[] |
    [.name, (.guestCpus|tostring), ((.memoryMb/1024)|floor|tostring), .family, .quota] | @tsv
  ' "$cache")"

  if [[ -z "$viable" ]]; then
    omc::log ERROR "GCP region $region has 0 viable machine types meeting:"
    omc::log ERROR "  >= 4 vCPU per node, family in (e2 n2 c3), $required_vcpu_total vCPU headroom"
    omc::log ERROR "Quotas: e2(CPUS)=$q_e2  n2(N2_CPUS)=$q_n2  c3(C3_CPUS)=$q_c3"
    omc::log ERROR "Request quota increase: https://console.cloud.google.com/iam-admin/quotas?service=compute.googleapis.com"
    omc::die "No viable GCP machine types"
  fi

  local header tsv
  header="$(printf 'NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)')"
  tsv="$header"$'\n'"$viable"

  omc::pick_from_menu "Viable GKE machine types in $region (need >= $required_vcpu_total vCPU total headroom)" "$tsv" "$override_var"
}
