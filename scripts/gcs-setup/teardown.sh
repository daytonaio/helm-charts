#!/usr/bin/env bash
# scripts/gcs-setup/teardown.sh — K8s-native Daytona BYOC teardown on GCP GKE.
# Pairs with up.sh. Idempotent. Continues on error.
#
# Reverse-create order:
#   1.  helm uninstall daytona-region
#   1b. helm uninstall ingress-nginx + release Service type=LoadBalancer so GCP
#       frees the LB forwarding/firewall rules before the cluster is deleted
#   2.  kubectl delete ns daytona
#   3.  delete HMAC keys for the GSA
#   4.  delete IAM policy binding on bucket
#   5.  delete GSA
#   6.  delete GCS bucket (recursive)
#   7.  delete GKE cluster
#   8.  cleanup local .state/
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
HMAC_FILE="$STATE_DIR/hmac.env"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  omc::log WARN "$PROMPTS_FILE missing — set CLUSTER_NAME, GCP_PROJECT, GCP_REGION, GCS_BUCKET env vars"
fi

if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi
if [[ -f "$HMAC_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$HMAC_FILE"
  set +a
fi

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${GCP_PROJECT:?GCP_PROJECT is required}"
: "${GCP_REGION:?GCP_REGION is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"

omc::log INFO "=== Daytona BYOC: GCP teardown for cluster '$CLUSTER_NAME' in '$GCP_PROJECT/$GCP_REGION' ==="
omc::confirm "This will DELETE the GKE cluster + GCS bucket + GSA + HMAC keys for '$CLUSTER_NAME'. Proceed?" \
  || { omc::log INFO "Aborted by operator."; exit 0; }

omc::need_cmd gcloud kubectl helm jq

gcloud config set project "$GCP_PROJECT" >/dev/null 2>&1 || true

# === 1. helm uninstall + release load balancers + delete namespace ==========
if kubectl get ns daytona >/dev/null 2>&1; then
  helm uninstall daytona-region -n daytona --wait --timeout 5m 2>/dev/null \
    && omc::log INFO "helm uninstalled daytona-region" \
    || omc::log WARN "helm uninstall failed or absent"
fi
# Uninstall ingress-nginx and delete any remaining Service type=LoadBalancer so
# GCP frees the forwarding + firewall rules BEFORE the cluster is deleted.
# up.sh never uninstalls ingress-nginx, so without this its LB (and the k8s-*
# forwarding/firewall rules) can orphan when the cluster delete races the
# cloud-controller. helm uninstall --wait also drops the snapshot PVC so its
# persistent disk is reclaimed before the cluster goes away.
helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 5m 2>/dev/null \
  && omc::log INFO "helm uninstalled ingress-nginx" \
  || omc::log WARN "ingress-nginx uninstall failed or absent"
if kubectl cluster-info >/dev/null 2>&1; then
  while IFS= read -r lb_line; do
    [[ -z "$lb_line" ]] && continue
    lb_ns="${lb_line%%/*}"; lb_name="${lb_line##*/}"
    kubectl delete svc "$lb_name" -n "$lb_ns" --wait=true --timeout=3m 2>/dev/null \
      && omc::log INFO "released LoadBalancer svc $lb_line" || true
  done < <(kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi
if kubectl get ns daytona >/dev/null 2>&1; then
  kubectl delete namespace daytona --wait=false 2>/dev/null \
    && omc::log INFO "namespace daytona deletion initiated" \
    || omc::log WARN "namespace delete failed or absent"
fi

GSA_NAME="daytona-byoc-${CLUSTER_NAME}"
GSA_EMAIL="${GSA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"

# === 2. HMAC keys ============================================================
if [[ -n "${HMAC_ACCESS_KEY:-}" ]]; then
  gcloud storage hmac update "$HMAC_ACCESS_KEY" --deactivate 2>/dev/null || true
  gcloud storage hmac delete  "$HMAC_ACCESS_KEY" 2>/dev/null \
    && omc::log INFO "HMAC key $HMAC_ACCESS_KEY deleted" \
    || omc::log WARN "HMAC key delete failed"
fi
# Sweep any remaining HMAC keys tied to this GSA in case state is missing.
gcloud storage hmac list --service-account "$GSA_EMAIL" --format='value(accessId)' 2>/dev/null \
  | while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      gcloud storage hmac update "$key" --deactivate 2>/dev/null || true
      gcloud storage hmac delete  "$key" 2>/dev/null && omc::log INFO "swept HMAC $key" || true
    done

# === 3. Bucket IAM + GSA =====================================================
gcloud storage buckets remove-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin" 2>/dev/null || true
if gcloud iam service-accounts describe "$GSA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "$GSA_EMAIL" --quiet 2>/dev/null \
    && omc::log INFO "GSA $GSA_EMAIL deleted" \
    || omc::log WARN "GSA delete failed"
fi

# === 4. GCS bucket ===========================================================
if gcloud storage buckets describe "gs://${GCS_BUCKET}" >/dev/null 2>&1; then
  gcloud storage rm --recursive --quiet "gs://${GCS_BUCKET}" 2>/dev/null \
    && omc::log INFO "GCS bucket gs://${GCS_BUCKET} deleted" \
    || omc::log WARN "bucket delete failed"
fi

# === 5. GKE cluster ==========================================================
if gcloud container clusters describe "$CLUSTER_NAME" --region "$GCP_REGION" >/dev/null 2>&1; then
  omc::log INFO "Deleting GKE cluster (this takes 5-10 min)..."
  gcloud container clusters delete "$CLUSTER_NAME" --region "$GCP_REGION" --quiet \
    && omc::log INFO "GKE cluster deleted" \
    || omc::log WARN "cluster delete failed"
fi

# === 6. Local state + kubeconfig =============================================
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  omc::log INFO "removed $STATE_DIR"
fi
kubectl config delete-context "gke_${GCP_PROJECT}_${GCP_REGION}_${CLUSTER_NAME}" 2>/dev/null || true
kubectl config delete-cluster "gke_${GCP_PROJECT}_${GCP_REGION}_${CLUSTER_NAME}" 2>/dev/null || true

cat >&2 <<EOF

==================== TEARDOWN COMPLETE ====================
Verify with:
  gcloud container clusters describe $CLUSTER_NAME --region $GCP_REGION
    (expect NOT_FOUND)
  gcloud storage buckets describe gs://${GCS_BUCKET}
    (expect 404)
  gcloud iam service-accounts describe $GSA_EMAIL
    (expect 404)
  gcloud compute forwarding-rules list --filter="name~'^k8s'" --project $GCP_PROJECT
    (expect empty — else delete leftover LB forwarding rules)
  gcloud compute disks list --filter="name~'pvc-'" --project $GCP_PROJECT
    (expect empty — else delete leftover snapshot persistent disks)
===========================================================
EOF
