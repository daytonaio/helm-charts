#!/usr/bin/env bash
# scripts/_lib/sku-data.sh — single source of truth for SKU family allowlists + rank tables.
# Sourced by sku-aws.sh, sku-azure.sh, sku-gcp.sh.
#
# Conventions:
#   * No `declare -A` (macOS bash 3.2 compat) — use space-separated strings + case.
#   * Higher rank = preferred (newer generation, better perf/$).
#   * x86_64 ONLY across all clouds (the chart's docker-installer downloads
#     Ubuntu 24.04 noble amd64 .debs; ARM/Graviton/tau-t2a are excluded).

# AWS instance type families (general-purpose + compute + memory + burstable),
# x86_64 ONLY (the chart's docker-installer pulls Ubuntu 24.04 amd64 .debs, so
# Graviton/ARM is excluded). Broad on purpose: a too-narrow list drops types an
# account/AZ can actually launch. Intel (i) and AMD (a) variants of m/c/r across
# generations 4-7, plus t3 burstable. Every family listed here MUST have an
# omc::sku_rank case below, or select(.rank > 0) in sku-aws.sh drops it.
export OMC_AWS_FAMILIES="m7i m7a c7i c7a r7i r7a m6i m6a c6i c6a r6i r6a m5 m5a c5 c5a r5 m4 c4 t3 t3a"

# Azure VM SKU families (D-series v3/v4/v5/v6 + B-series burstable, all x86_64)
# These match the `family` field in `az vm list-skus` / `az vm list-usage`.
export OMC_AZURE_FAMILY_PREFIXES="standardDSv6Family standardDv6Family standardDDv6Family standardDADSv6Family standardDSv5Family standardDv5Family standardDASv5Family standardDDv5Family standardDADSv5Family standardDDSv5Family standardDADv5Family standardDSv4Family standardDv4Family standardDASv4Family standardDDv4Family standardDDSv4Family standardDSv3Family standardDv3Family standardBsFamily"

# GCP machine type families (cost-optimized + general + compute, all x86_64)
export OMC_GCP_FAMILIES="e2 n2 c3"

# omc::sku_rank <cloud> <family> -> integer (higher = better)
# Used as jq secondary sort key. Returns 0 for unknown families.
omc::sku_rank() {
  local cloud="$1" family="$2"
  case "$cloud:$family" in
    aws:m7i) echo 90 ;;
    aws:m7a) echo 89 ;;
    aws:c7i) echo 88 ;;
    aws:c7a) echo 87 ;;
    aws:r7i) echo 86 ;;
    aws:r7a) echo 85 ;;
    aws:m6i) echo 80 ;;
    aws:m6a) echo 79 ;;
    aws:c6i) echo 78 ;;
    aws:c6a) echo 77 ;;
    aws:r6i) echo 76 ;;
    aws:r6a) echo 75 ;;
    aws:m5)  echo 70 ;;
    aws:m5a) echo 69 ;;
    aws:c5)  echo 68 ;;
    aws:c5a) echo 67 ;;
    aws:r5)  echo 66 ;;
    aws:m4)  echo 50 ;;
    aws:c4)  echo 49 ;;
    aws:t3a) echo 30 ;;
    aws:t3)  echo 29 ;;
    azure:standardDSv6Family)   echo 70 ;;
    azure:standardDv6Family)    echo 69 ;;
    azure:standardDDv6Family)   echo 68 ;;
    azure:standardDADSv6Family) echo 67 ;;
    azure:standardDSv5Family)   echo 60 ;;
    azure:standardDv5Family)    echo 59 ;;
    azure:standardDASv5Family)  echo 58 ;;
    azure:standardDDv5Family)   echo 57 ;;
    azure:standardDADSv5Family) echo 56 ;;
    azure:standardDDSv5Family)  echo 55 ;;
    azure:standardDADv5Family)  echo 54 ;;
    azure:standardDSv4Family)   echo 50 ;;
    azure:standardDv4Family)    echo 49 ;;
    azure:standardDASv4Family)  echo 48 ;;
    azure:standardDDv4Family)   echo 47 ;;
    azure:standardDDSv4Family)  echo 46 ;;
    azure:standardDSv3Family)   echo 40 ;;
    azure:standardDv3Family)    echo 39 ;;
    azure:standardBsFamily)     echo 20 ;;
    gcp:c3) echo 60 ;;
    gcp:n2) echo 50 ;;
    gcp:e2) echo 40 ;;
    *) echo 0 ;;
  esac
}
