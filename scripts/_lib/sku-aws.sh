#!/usr/bin/env bash
# scripts/_lib/sku-aws.sh — quota-aware AWS EC2 instance type selection.
# Sourced by scripts/aws-setup/up.sh.
#
# Requires: aws, jq, awk; STATE_DIR var; sku-data.sh and common.sh sourced first.

# omc::aws_select_instance_type REGION REQUIRED_VCPU [override_var=OMC_INSTANCE_TYPE]
#
# Picks an EC2 instance type that:
#   1. is offered in REGION (describe-instance-type-offerings)
#   2. is in the OMC_AWS_FAMILIES allowlist (x86_64 only)
#   3. has VCpuInfo.DefaultVCpus >= REQUIRED_VCPU
#   4. fits within the Standard On-Demand vCPU quota (L-1216C47A) headroom, so
#      the menu only lists types this account can actually launch. If the quota
#      cannot be read (servicequotas:GetServiceQuota denied), this filter is
#      skipped (all offered types shown) rather than hiding everything.
#   5. is PREFERRED when offered in >= 2 of the region's AZs (multi-AZ types
#      sort first and the count shows in the menu) — a SOFT signal, never a hard
#      filter, so a flaky/empty per-AZ lookup can't hide every type. Bare-metal
#      (.metal) is excluded.
#
# Outputs the chosen instance type name to STDOUT. Menu + logs go to STDERR.
# The L-1216C47A quota covers all (a,c,d,h,i,m,r,t,z) family vCPUs combined;
# "used" is approximated by counting running instances in matching families.
omc::aws_select_instance_type() {
  local region="$1" required_vcpu="$2" override_var="${3:-OMC_INSTANCE_TYPE}"
  omc::need_cmd aws jq awk
  local cache="$STATE_DIR/skus-aws-$region.json"

  local offerings
  offerings="$(aws ec2 describe-instance-type-offerings \
    --location-type region --region "$region" \
    --filters "Name=location,Values=$region" \
    --query 'InstanceTypeOfferings[].InstanceType' --output json 2>/dev/null)" \
    || omc::die "aws ec2 describe-instance-type-offerings failed for $region (check aws credentials / region)"

  local fam_filter
  fam_filter="$(printf '%s' "$OMC_AWS_FAMILIES" | tr ' ' '|')"
  local candidates
  candidates="$(jq -r --arg f "^($fam_filter)\\." \
    '.[] | select(test($f))' <<< "$offerings" | sort -u)"

  if [[ -z "$candidates" ]]; then
    omc::die "No AWS instance types in $region match family allowlist ($OMC_AWS_FAMILIES). Check region or update scripts/_lib/sku-data.sh."
  fi

  if ! omc::cache_fresh "$cache" 15; then
    # Pull ALL x86_64 instance types the region supports (CLI auto-paginates),
    # not a capped enumeration of the allowlist — the family/rank/vCPU/quota/AZ
    # filters below narrow it. Avoids the 100-item --instance-types arg cap that
    # silently truncated a broadened allowlist.
    aws ec2 describe-instance-types --region "$region" \
      --filters "Name=processor-info.supported-architecture,Values=x86_64" \
      --query 'InstanceTypes[].{name:InstanceType,vcpu:VCpuInfo.DefaultVCpus,mem:MemoryInfo.SizeInMiB,arch:ProcessorInfo.SupportedArchitectures}' \
      --output json > "$cache" \
      || omc::die "aws ec2 describe-instance-types failed for $region"
  fi

  # EC2 vCPU quota (L-1216C47A: Running On-Demand Standard a,c,d,h,i,m,r,t,z).
  # New accounts default low (often 5 vCPU), so a too-big instance type fails at
  # node launch. Read the quota and HIDE any type that can't fit, so the menu
  # only lists types this account can actually launch. If the quota can't be
  # read (servicequotas:GetServiceQuota denied), skip the filter instead of
  # hiding everything.
  local quota_known=1 quota_limit="" quota_int quota_used headroom
  quota_limit="$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --region "$region" --query 'Quota.Value' --output text 2>/dev/null || true)"
  if [[ -z "$quota_limit" || "$quota_limit" == "None" ]]; then
    quota_known=0
    quota_limit=0
    omc::log WARN "Could not read EC2 vCPU quota (L-1216C47A) in $region — showing all offered types, unfiltered."
    omc::log WARN "Grant servicequotas:GetServiceQuota to this identity for launchable-only results."
  fi
  quota_int="${quota_limit%.*}"
  # Approx in-use vCPUs by counting running Standard-family instances (0 on a
  # fresh account). Under-counts vCPUs, so headroom is a slight over-estimate —
  # acceptable: AWS rejects an over-quota launch and you just re-pick.
  quota_used="$( { aws ec2 describe-instances --region "$region" \
      --filters 'Name=instance-state-name,Values=running' \
      --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null || true; } \
    | tr '[:space:]' '\n' \
    | awk 'BEGIN{c=0} /^[acdhimrtz][0-9]/ {n=split($0,p,"."); if(n>=2){c+=1}} END{print c}')"
  quota_used="${quota_used:-0}"
  if [[ "$quota_known" -eq 1 ]]; then
    headroom=$(( quota_int - quota_used ))
    if (( headroom < 0 )); then headroom=0; fi
  else
    headroom=1000000   # no quota info -> effectively no quota filter
  fi

  # Per-AZ offerings: how many AZs offer each type. A type offered in the REGION
  # can still be scarce in the AZs an EKS node group lands in, risking
  # InsufficientInstanceCapacity. We use this as a SOFT preference only (multi-AZ
  # types sort first) and surface the count in the menu — NEVER a hard filter, so
  # a flaky/empty AZ response can't zero out the list. azcount is kept as valid
  # JSON ('{}' when unavailable) so --argjson can never error out the main jq.
  local az_ok=0 azcount='{}' az_json az_tmp
  az_json="$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone --region "$region" \
    --query 'InstanceTypeOfferings[].{t:InstanceType,az:Location}' \
    --output json 2>/dev/null || true)"
  if [[ -n "$az_json" ]] && jq -e 'type=="array" and length>0' >/dev/null 2>&1 <<< "$az_json"; then
    az_tmp="$(jq -c 'reduce .[] as $o ({}; .[$o.t] = ((.[$o.t] // 0) + 1))' <<< "$az_json" 2>/dev/null || true)"
    if [[ -n "$az_tmp" ]] && jq -e 'type=="object" and length>0' >/dev/null 2>&1 <<< "$az_tmp"; then
      azcount="$az_tmp"
      az_ok=1
    fi
  fi
  [[ "$az_ok" -eq 1 ]] || omc::log WARN "Per-AZ offerings unavailable in $region — AZ column shows '?', multi-AZ preference skipped (selection still proceeds)."

  local viable ranks_json
  ranks_json="$(_omc_aws_ranks_json)"
  viable="$(jq -r \
    --argjson req "$required_vcpu" \
    --argjson room "$headroom" \
    --argjson azc "$azcount" \
    --argjson ranks "$ranks_json" '
    map(. + {family: (.name | split(".") | .[0])}) |
    map(select(.arch | index("x86_64"))) |
    map(select((.name | test("\\.metal")) | not)) |
    map(select(.vcpu >= $req)) |
    map(select(.vcpu <= $room)) |
    map(. + {rank: ($ranks[.family] // 0)}) |
    map(select(.rank > 0)) |
    map(. + {azs: ($azc[.name] // 0)}) |
    sort_by([ (if .azs >= 2 then 0 else 1 end), (- .rank), .vcpu, .name ]) |
    .[0:20] |
    .[] |
    [.name, (.vcpu|tostring), ((.mem/1024)|floor|tostring), .family, (.azs|tostring)] | @tsv
  ' "$cache")"

  if [[ -z "$viable" ]]; then
    if [[ "$quota_known" -eq 1 && "$headroom" -lt "$required_vcpu" ]]; then
      omc::log ERROR "EC2 vCPU quota in $region is too low: limit=${quota_int}, in-use~=${quota_used}, free~=${headroom}, but each node needs >= ${required_vcpu} vCPU."
      omc::log ERROR "This is an ACCOUNT quota, not region capacity — switching regions rarely helps (new-account defaults are low everywhere)."
      omc::log ERROR "Request an increase (e.g. to 32) and re-run up.sh:"
      omc::log ERROR "  aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 32 --region $region"
      omc::log ERROR "  Console: https://${region}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
      omc::die "EC2 vCPU quota too low in $region"
    fi
    omc::log ERROR "Region $region offers 0 EC2 types in the family allowlist ($OMC_AWS_FAMILIES) meeting $required_vcpu vCPU within the vCPU quota."
    omc::log ERROR "Widen OMC_AWS_FAMILIES in scripts/_lib/sku-data.sh, raise the vCPU quota, or try another region."
    omc::die "No viable AWS instance types in $region"
  fi

  local header tsv qcol
  if [[ "$quota_known" -eq 1 ]]; then qcol="${headroom}/${quota_int}"; else qcol="?/?"; fi
  header="$(printf 'NAME\tvCPU\tMEM(GiB)\tFAMILY\tAZs\tvCPU-QUOTA(free/limit)')"
  tsv="$header"
  while IFS=$'\t' read -r name vcpu mem family azs; do
    [[ -z "$name" ]] && continue
    if [[ "$az_ok" -ne 1 ]]; then azs="?"; fi
    tsv+=$'\n'"${name}"$'\t'"${vcpu}"$'\t'"${mem}"$'\t'"${family}"$'\t'"${azs}"$'\t'"${qcol}"
  done <<< "$viable"

  omc::pick_from_menu "Viable EC2 instance types in $region (need >= $required_vcpu vCPU per node)" "$tsv" "$override_var"
}

_omc_aws_ranks_json() {
  # up.sh sets IFS=$'\n\t' (no space). OMC_AWS_FAMILIES is space-separated, so
  # force a normal IFS locally or the for-loop won't split it (collapsing every
  # family into one bogus key that ranks 0 — which drops every instance type).
  local first=1 fam IFS=$' \t\n'
  printf '{'
  for fam in $OMC_AWS_FAMILIES; do
    [[ $first -eq 0 ]] && printf ','
    printf '"%s":%s' "$fam" "$(omc::sku_rank aws "$fam")"
    first=0
  done
  printf '}'
}

# omc::aws_eks_ubuntu2404_version REGION
#
# Prints the newest k8s minor version that BOTH (a) has a Canonical Ubuntu 24.04
# (noble) amd64 EKS AMI published in REGION and (b) EKS currently offers for new
# clusters. eksctl's amiFamily=Ubuntu2404 can only resolve versions Canonical
# has published an image for; pinning one without an image fails eksctl with
# "unable to determine AMI ... image family Ubuntu2404". Canonical's AWS account
# id is 099720109477. Falls back to the newest 24.04 AMI version when the EKS
# version list is unavailable (older aws-cli). Returns non-zero (prints nothing)
# when no 24.04 AMI exists in REGION.
omc::aws_eks_ubuntu2404_version() {
  local region="$1"
  local IFS=$' \t\n'
  local ami_versions eks_versions v
  # Newest-first list of k8s versions that have a published 24.04 amd64 AMI.
  ami_versions="$(aws ec2 describe-images --region "$region" --owners 099720109477 \
    --filters "Name=name,Values=ubuntu-eks/k8s_*/*24.04*amd64*" "Name=state,Values=available" \
    --query 'Images[].Name' --output text 2>/dev/null \
    | tr '[:space:]' '\n' \
    | grep -oE 'k8s_[0-9]+\.[0-9]+' \
    | sed 's/^k8s_//' \
    | sort -t. -k1,1nr -k2,2nr -u)" || true
  [[ -n "$ami_versions" ]] || return 1
  # Versions EKS currently offers for NEW clusters (empty on older aws-cli).
  eks_versions="$(aws eks describe-cluster-versions --region "$region" \
    --query 'clusterVersions[].clusterVersion' --output text 2>/dev/null \
    | tr '[:space:]' '\n' | sort -u)" || true
  if [[ -n "$eks_versions" ]]; then
    # Newest AMI version that EKS also offers.
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      if printf '%s\n' "$eks_versions" | grep -qxF "$v"; then
        printf '%s' "$v"; return 0
      fi
    done <<< "$ami_versions"
  fi
  # Fallback: newest 24.04 AMI version (EKS version list unavailable/no overlap).
  printf '%s' "$(printf '%s\n' "$ami_versions" | head -n1)"
}
