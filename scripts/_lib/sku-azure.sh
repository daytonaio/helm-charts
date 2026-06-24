#!/usr/bin/env bash
# scripts/_lib/sku-azure.sh — quota-aware Azure VM SKU selection.
# Sourced by scripts/azure-setup/up.sh.
#
# Requires: az, jq, awk; STATE_DIR var; sku-data.sh and common.sh sourced first.

# omc::azure_select_vm_size LOCATION REQUIRED_VCPU_TOTAL [override_var=OMC_INSTANCE_TYPE]
#
# Picks an Azure VM size that:
#   1. is in the OMC_AZURE_FAMILY_PREFIXES allowlist (D-series v3-v6 + B-series)
#   2. is x86_64 (excludes Arm64) and HyperVGenerations supports V2
#   3. is NOT restricted in the subscription (NotAvailableForSubscription)
#   4. has vCPUs per node >= 4
#   5. has family quota headroom >= REQUIRED_VCPU_TOTAL
#
# REQUIRED_VCPU_TOTAL is the SUM across pools sharing this SKU:
#   azure-setup = vCPU * 3   (2 system + 1 sandbox)
#
# Outputs the chosen VM size name to STDOUT. Menu + logs go to STDERR.
omc::azure_select_vm_size() {
  local location="$1" required_vcpu_total="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
  omc::need_cmd az jq awk
  local cache="$STATE_DIR/skus-azure-$location.json"

  if ! omc::cache_fresh "$cache" 15; then
    omc::log INFO "Fetching Azure VM SKUs for $location (5-10s, cached for 15 min)..."
    az vm list-skus -l "$location" --resource-type virtualMachines --all -o json > "$cache" \
      || omc::die "az vm list-skus failed for $location (check az login / subscription)"
  fi

  local usage
  usage="$(az vm list-usage --location "$location" -o json 2>/dev/null)" \
    || omc::die "az vm list-usage failed for $location"

  local total_cores_used total_cores_limit total_cores_avail
  total_cores_used="$(jq -r 'first(.[] | select(.name.value=="cores") | .currentValue) // empty' <<< "$usage")"
  total_cores_limit="$(jq -r 'first(.[] | select(.name.value=="cores") | .limit) // empty' <<< "$usage")"
  if [[ -n "$total_cores_limit" ]]; then
    total_cores_avail=$((total_cores_limit - total_cores_used))
    omc::log INFO "Azure $location regional vCPU quota: ${total_cores_used}/${total_cores_limit} (available: ${total_cores_avail}, need: ${required_vcpu_total})"
    if (( total_cores_avail < required_vcpu_total )); then
      omc::log ERROR ""
      omc::log ERROR "=== REGIONAL vCPU QUOTA INSUFFICIENT IN $location ==="
      omc::log ERROR "  Available: $total_cores_avail vCPU  (used=$total_cores_used / limit=$total_cores_limit)"
      omc::log ERROR "  Required:  $required_vcpu_total vCPU"
      omc::log ERROR ""
      omc::log ERROR "This is the TOTAL REGIONAL cap and blocks ALL families regardless of per-family quota."
      omc::log ERROR ""
      omc::log ERROR "Request a quota increase (fastest path):"
      omc::log ERROR "  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
      omc::log ERROR "    Provider: Compute   |  Quota: 'Total Regional vCPUs'"
      omc::log ERROR "    Region: $location   |  New limit: $((required_vcpu_total + 8)) or higher"
      omc::log ERROR ""
      omc::log ERROR "Auto-approval is usually instant for limits under ~50 vCPU."
      omc::die "Regional vCPU quota too low in $location ($total_cores_avail < $required_vcpu_total)"
    fi
  else
    omc::log INFO "Azure $location: regional 'cores' quota entry not reported (continuing with per-family check)."
  fi

  local fam_filter ranks_json
  fam_filter="$(printf '%s' "$OMC_AZURE_FAMILY_PREFIXES" | tr ' ' '|')"
  ranks_json="$(_omc_azure_ranks_json)"

  local n_total n_loc n_fam n_unrestricted
  n_total="$(jq 'length' "$cache")"
  n_loc="$(jq --arg loc "$location" '[.[] | select(.locations | index($loc))] | length' "$cache")"
  n_fam="$(jq --arg loc "$location" --arg fams "$fam_filter" '[.[] | select(.locations | index($loc)) | select(.family | test($fams; "i"))] | length' "$cache")"
  n_unrestricted="$(jq --arg loc "$location" --arg fams "$fam_filter" '[.[] | select(.locations | index($loc)) | select(.family | test($fams; "i")) | select(([.restrictions[]? | select(.type == "Location")] | length) == 0)] | length' "$cache")"
  omc::log INFO "Azure SKU filter funnel: $n_total total -> $n_loc in $location -> $n_fam in allowed families -> $n_unrestricted location-unrestricted"
  if (( n_fam > 0 )) && (( n_unrestricted == 0 )); then
    local restriction_summary
    restriction_summary="$(jq -r --arg loc "$location" --arg fams "$fam_filter" '
      [.[] | select(.locations | index($loc)) | select(.family | test($fams; "i"))] |
      [.[] | .restrictions[]? | "\(.type):\(.reasonCode)"] |
      group_by(.) | map({key: .[0], count: length}) | sort_by(-.count) |
      .[] | "  \(.count)x \(.key)"
    ' "$cache" 2>/dev/null)"
    omc::log INFO "Restriction breakdown across $n_fam allowed-family SKUs:"
    printf '%s\n' "$restriction_summary" >&2
  fi

  local viable
  viable="$(jq -r \
    --arg loc "$location" \
    --arg fams "$fam_filter" \
    --argjson req_total "$required_vcpu_total" \
    --argjson ranks "$ranks_json" \
    --argjson usage "$usage" '
    ($usage | map({key: .name.value, value: {used: .currentValue, limit: .limit}}) | from_entries) as $u |
    map(
      select(.resourceType == "virtualMachines")
      | select(.locations | index($loc))
      | select(.family | test($fams; "i"))
      | select(([.restrictions[]? | select(.type == "Location")] | length) == 0)
      | select(([.capabilities[]? | select(.name=="HyperVGenerations") | .value] | join(",") | test("V2")))
      | select(([.capabilities[]? | select(.name=="CpuArchitectureType") | .value] | join(",") | test("Arm64")) | not)
      | . + {
          vcpu:        (([.capabilities[]? | select(.name=="vCPUs")    | .value][0] // "0") | tonumber),
          memgb:       (([.capabilities[]? | select(.name=="MemoryGB") | .value][0] // "0") | tonumber),
          rank:        ($ranks[.family] // 0),
          quota_used:  (($u[.family].used  // 0) | tostring | tonumber),
          quota_limit: (($u[.family].limit // 0) | tostring | tonumber)
        }
      | select(.vcpu >= 4)
      | select((.quota_limit - .quota_used) >= $req_total)
    ) |
    unique_by(.name) |
    sort_by([-.rank, .vcpu, .name]) |
    .[0:5] |
    .[] |
    [.name, (.vcpu|tostring), (.memgb|tostring), .family, "\(.quota_used)/\(.quota_limit)"] | @tsv
  ' "$cache")"

  if [[ -z "$viable" ]]; then
    omc::log ERROR ""
    omc::log ERROR "=== 0 VIABLE AZURE VM SKUs in $location ==="
    omc::log ERROR "Filter funnel: $n_total total -> $n_loc in region -> $n_fam in allowed families -> $n_unrestricted unrestricted -> 0 with $required_vcpu_total vCPU per-family headroom"
    omc::log ERROR ""
    if (( n_unrestricted > 0 )); then
      omc::log ERROR "$n_unrestricted SKU(s) passed family + restriction filters but ALL failed family-quota headroom."
      omc::log ERROR "This is a per-family quota issue (the families you have SKU access to have <$required_vcpu_total vCPU free)."
    else
      omc::log ERROR "0 SKUs in allowed families are unrestricted in your subscription."
      omc::log ERROR "Either the families you have access to aren't in our allowlist, or all are restricted."
    fi
    omc::log ERROR ""
    omc::log ERROR "Diagnostic — see actual per-family quotas:"
    omc::log ERROR "  az vm list-usage --location $location -o table | grep -iE 'cores|Family|vCPU'"
    omc::log ERROR ""
    omc::log ERROR "Request a per-family quota increase (fastest path):"
    omc::log ERROR "  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
    omc::log ERROR "    Provider: Compute   |  Quota: 'Standard DSv5 Family vCPUs' (or your preferred family)"
    omc::log ERROR "    Region: $location   |  New limit: $((required_vcpu_total + 8))"
    omc::log ERROR ""
    omc::log ERROR "Escape hatch — bypass our filter and let Azure validate directly:"
    omc::log ERROR "  OMC_INSTANCE_TYPE=Standard_D4s_v4 OMC_INSTANCE_TYPE_FORCE=1 bash <script>"
    omc::log ERROR "  (AKS will still reject at create time if quota is truly 0)"
    omc::die "No viable Azure VM SKUs"
  fi

  local header tsv
  header="$(printf 'NAME\tvCPU\tMEM(GiB)\tFAMILY\tQUOTA(used/limit)')"
  tsv="$header"$'\n'"$viable"

  omc::pick_from_menu "Viable AKS VM SKUs in $location (need >= $required_vcpu_total vCPU total headroom)" "$tsv" "$override_var"
}

_omc_azure_ranks_json() {
  # up.sh sets IFS=$'\n\t' (no space). OMC_AZURE_FAMILY_PREFIXES is space-
  # separated, so force a normal IFS locally or the for-loop won't split it
  # (collapsing every family into one bogus key that ranks 0 — which drops every
  # VM SKU). Mirrors the fix in sku-aws.sh:_omc_aws_ranks_json.
  local first=1 fam IFS=$' \t\n'
  printf '{'
  for fam in $OMC_AZURE_FAMILY_PREFIXES; do
    [[ $first -eq 0 ]] && printf ','
    printf '"%s":%s' "$fam" "$(omc::sku_rank azure "$fam")"
    first=0
  done
  printf '}'
}
