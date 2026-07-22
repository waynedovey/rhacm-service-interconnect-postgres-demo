#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

log "RHACM policies"
oc get policy -n si-demo-policies

log "RHACM placement and GitOps registration"
oc get placement,gitopscluster -n openshift-gitops

log "Argo CD applications"
oc get applicationset,application -n openshift-gitops

for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  log "${cluster}: operators"
  site_oc "${cluster}" get subscriptions.operators.coreos.com -A |
    grep -E 'skupper|external-secrets|cloudnative' || true

  log "${cluster}: External Secrets"
  site_oc "${cluster}" get clustersecretstore
  site_oc "${cluster}" get externalsecret -A

  log "${cluster}: Service Interconnect"
  site_oc "${cluster}" -n bookinfo \
    get site,accessgrant,accesstoken,link,connector,listener 2>/dev/null || true

  log "${cluster}: PostgreSQL"
  site_oc "${cluster}" -n bookinfo \
    get cluster.postgresql.cnpg.io,pods,pvc

  log "${cluster}: Bookinfo"
  site_oc "${cluster}" -n bookinfo get deployment,service,route
done
