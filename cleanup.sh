#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

REMOVE_OPERATORS=false
if [[ "${1:-}" == "--remove-operators" ]]; then
  REMOVE_OPERATORS=true
fi

log "Removing ApplicationSet and GitOps registration"
oc -n openshift-gitops delete applicationsets.argoproj.io si-demo \
  --ignore-not-found
oc -n openshift-gitops delete gitopscluster si-demo \
  --ignore-not-found
oc -n openshift-gitops delete placement si-demo-clusters \
  --ignore-not-found
oc -n openshift-gitops delete appproject si-demo \
  --ignore-not-found

for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  if [[ -f "${KUBECONFIG_DIR}/${cluster}.kubeconfig" ]]; then
    log "Removing demo namespaces from ${cluster}"
    site_oc "${cluster}" delete namespace bookinfo vault-demo \
      --ignore-not-found \
      --wait=true \
      --timeout=10m
  else
    warn "No cached kubeconfig for ${cluster}; skipping managed-cluster namespace deletion"
  fi
done

if [[ "${REMOVE_OPERATORS}" == "true" ]]; then
  log "Removing RHACM operator policies"
  oc delete -k "${ROOT_DIR}/hub/policies" --ignore-not-found
else
  warn "Operator policies were preserved. Use --remove-operators to remove them."
fi

log "Removing local generated files"
rm -rf "${WORK_DIR}"

ok "Cleanup requested. The OpenShift clusters were not deleted."
