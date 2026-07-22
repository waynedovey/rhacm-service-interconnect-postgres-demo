#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

log "RHACM policies"
oc get policy -n si-demo-policies

log "RHACM placement and GitOps registration"
oc get managedclustersetbinding,placement,placementdecision,gitopscluster \
  -n openshift-gitops

log "ApplicationSet Placement generator"
oc get configmap ocm-placement-generator -n openshift-gitops -o yaml
oc auth can-i list placementdecisions.cluster.open-cluster-management.io \
  -n openshift-gitops \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-applicationset-controller

log "Argo CD applications"
oc get applicationsets.argoproj.io -n openshift-gitops
oc get applications.argoproj.io -n openshift-gitops

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
