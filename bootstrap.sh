#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

REPO_URL=""
REVISION="main"

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap.sh --repo-url https://github.com/ORG/REPO.git [--revision main]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --revision)
      REVISION="${2:-main}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${REPO_URL}" ]] || {
  usage
  die "--repo-url is required"
}

BOOTSTRAP_LOCK="${WORK_DIR}/bootstrap.lock"

if ! mkdir "${BOOTSTRAP_LOCK}" 2>/dev/null; then
  EXISTING_PID="$(
    cat "${BOOTSTRAP_LOCK}/pid" 2>/dev/null || true
  )"

  if [[ -n "${EXISTING_PID}" ]] &&
     kill -0 "${EXISTING_PID}" 2>/dev/null; then
    die "Another bootstrap process is already running with PID ${EXISTING_PID}"
  fi

  warn "Removing stale bootstrap lock"
  rm -rf "${BOOTSTRAP_LOCK}"
  mkdir "${BOOTSTRAP_LOCK}"
fi

printf '%s\n' "$$" > "${BOOTSTRAP_LOCK}/pid"

remove_bootstrap_lock() {
  rm -rf "${BOOTSTRAP_LOCK}"
}

trap remove_bootstrap_lock EXIT INT TERM

for cmd in oc python3 openssl; do
  require_cmd "${cmd}"
done

log "Checking RHACM hub access"
oc whoami >/dev/null
oc auth can-i '*' '*' --all-namespaces | grep -q yes ||
  die "The current user must have cluster-admin privileges"

log "Waiting for the two managed clusters"
wait_until "${SITE_A_CLUSTER} is Available" 3600 managed_cluster_available "${SITE_A_CLUSTER}"
wait_until "${SITE_B_CLUSTER} is Available" 3600 managed_cluster_available "${SITE_B_CLUSTER}"

log "Applying placement labels"
oc label managedcluster "${SITE_A_CLUSTER}" \
  environment=service-interconnect-demo \
  application=bookinfo \
  site=site-a \
  database-role=primary \
  --overwrite

oc label managedcluster "${SITE_B_CLUSTER}" \
  environment=service-interconnect-demo \
  application=bookinfo \
  site=site-b \
  database-role=replica \
  --overwrite

log "Installing operators with RHACM policies"
oc apply -k "${ROOT_DIR}/hub/policies"

log "Waiting for RHACM Placement decisions"
wait_until "local-cluster policy placement selects local-cluster" 600 \
  placement_has_cluster si-demo-policies local-cluster local-cluster
wait_until "managed policy placement selects ${SITE_A_CLUSTER}" 600 \
  placement_has_cluster si-demo-policies si-demo-managed-clusters "${SITE_A_CLUSTER}"
wait_until "managed policy placement selects ${SITE_B_CLUSTER}" 600 \
  placement_has_cluster si-demo-policies si-demo-managed-clusters "${SITE_B_CLUSTER}"

show_placement_decisions si-demo-policies

log "Waiting for RHACM policies to become compliant"
wait_until "GitOps operator policy is compliant" 3600 \
  policy_compliant install-openshift-gitops
wait_until "Service Interconnect policy is compliant" 3600 \
  policy_compliant install-service-interconnect
wait_until "External Secrets policy is compliant" 3600 \
  policy_compliant install-external-secrets
wait_until "CloudNativePG policy is compliant" 3600 \
  policy_compliant install-cloudnative-pg

log "Waiting for hub OpenShift GitOps"
wait_until "ApplicationSet CRD on hub" 1800 \
  oc get crd applicationsets.argoproj.io
wait_until "GitOpsCluster CRD on hub" 1800 \
  oc get crd gitopsclusters.apps.open-cluster-management.io
wait_until "openshift-gitops namespace" 1800 \
  oc get namespace openshift-gitops

log "Creating RHACM GitOps placement and registration"
oc apply -f "${ROOT_DIR}/hub/gitops/base.yaml"

wait_until "GitOps placement selects ${SITE_A_CLUSTER}" 600 \
  placement_has_cluster openshift-gitops si-demo-clusters "${SITE_A_CLUSTER}"
wait_until "GitOps placement selects ${SITE_B_CLUSTER}" 600 \
  placement_has_cluster openshift-gitops si-demo-clusters "${SITE_B_CLUSTER}"

show_placement_decisions openshift-gitops

rendered_appset="${WORK_DIR}/applicationset.yaml"
python3 - "${ROOT_DIR}/hub/gitops/applicationset.yaml.tpl" \
  "${rendered_appset}" "${REPO_URL}" "${REVISION}" <<'PY'
from pathlib import Path
import sys
source, target, repo, revision = sys.argv[1:]
text = Path(source).read_text()
text = text.replace("__REPO_URL__", repo)
text = text.replace("__REVISION__", revision)
Path(target).write_text(text)
PY

log "Retrieving Hive admin kubeconfigs"
SITE_A_KUBECONFIG="$(get_cluster_kubeconfig "${SITE_A_CLUSTER}")"
SITE_B_KUBECONFIG="$(get_cluster_kubeconfig "${SITE_B_CLUSTER}")"
ok "Site A kubeconfig: ${SITE_A_KUBECONFIG}"
ok "Site B kubeconfig: ${SITE_B_KUBECONFIG}"

log "Waiting for managed-cluster operator CRDs"
for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  wait_until "${cluster}: Service Interconnect CRDs" 3600 \
    cluster_crd_exists "${cluster}" sites.skupper.io
  wait_until "${cluster}: External Secrets CRDs" 3600 \
    cluster_crd_exists "${cluster}" externalsecrets.external-secrets.io
  wait_until "${cluster}: CloudNativePG CRDs" 3600 \
    cluster_crd_exists "${cluster}" clusters.postgresql.cnpg.io
done

log "Preparing temporary demo credentials"
DEMO_ENV="${WORK_DIR}/demo.env"
if [[ -f "${DEMO_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${DEMO_ENV}"
else
  VAULT_TOKEN="$(openssl rand -hex 24)"
  POSTGRES_PASSWORD="$(openssl rand -base64 30 | tr -d '\n' | tr '/+' '_-')"
  cat > "${DEMO_ENV}" <<EOF
VAULT_TOKEN='${VAULT_TOKEN}'
POSTGRES_PASSWORD='${POSTGRES_PASSWORD}'
EOF
  chmod 600 "${DEMO_ENV}"
fi

for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  log "Creating Vault bootstrap secrets on ${cluster}"

  site_oc "${cluster}" create namespace vault-demo \
    --dry-run=client -o yaml |
    site_oc "${cluster}" apply -f -

  site_oc "${cluster}" wait \
    --for=jsonpath='{.status.phase}'=Active \
    namespace/vault-demo \
    --timeout=2m

  site_oc "${cluster}" -n vault-demo create secret generic vault-root-token \
    --from-literal=token="${VAULT_TOKEN}" \
    --dry-run=client -o yaml |
    site_oc "${cluster}" apply -f -

  site_oc "${cluster}" -n vault-demo create secret generic vault-auth \
    --from-literal=token="${VAULT_TOKEN}" \
    --dry-run=client -o yaml |
    site_oc "${cluster}" apply -f -

  site_oc "${cluster}" -n vault-demo get secret \
    vault-root-token vault-auth
done

log "Vault bootstrap Secrets exist before enabling the Argo CD applications"


log "Enabling the Argo CD applications after bootstrap Secrets are ready"
oc apply -f "${rendered_appset}"

log "Waiting for Argo CD applications"
wait_until "Site A Argo CD application" 1800 \
  oc -n openshift-gitops get application "${SITE_A_CLUSTER}-si-demo"
wait_until "Site B Argo CD application" 1800 \
  oc -n openshift-gitops get application "${SITE_B_CLUSTER}-si-demo"

log "Waiting for demo Vault on both clusters"
for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  wait_until "${cluster}: Vault deployment exists" 1800 \
    site_oc "${cluster}" -n vault-demo get deployment vault-demo
  site_oc "${cluster}" -n vault-demo rollout status deployment/vault-demo --timeout=20m
done

log "Seeding database application credentials in both Vaults"
for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  vault_put_literals "${cluster}" "${VAULT_TOKEN}" "bookinfo/app" \
    username=bookinfo \
    password="${POSTGRES_PASSWORD}" \
    database=bookinfo
done

for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  wait_until "${cluster}: bookinfo-db-app secret from ESO" 1800 \
    secret_exists "${cluster}" bookinfo bookinfo-db-app
done

log "Waiting for Site A PostgreSQL primary"
wait_until "Site A CloudNativePG primary is Ready" 3600 \
  cnpg_ready "${SITE_A_CLUSTER}" bookinfo-db

TMP_CERT_DIR="${WORK_DIR}/replication-certs"
mkdir -p "${TMP_CERT_DIR}"

get_secret_key "${SITE_A_CLUSTER}" bookinfo bookinfo-db-replication tls.crt \
  > "${TMP_CERT_DIR}/tls.crt"
get_secret_key "${SITE_A_CLUSTER}" bookinfo bookinfo-db-replication tls.key \
  > "${TMP_CERT_DIR}/tls.key"
get_secret_key "${SITE_A_CLUSTER}" bookinfo bookinfo-db-ca ca.crt \
  > "${TMP_CERT_DIR}/ca.crt"

log "Storing PostgreSQL replication certificates in Site B Vault"
vault_put_files "${SITE_B_CLUSTER}" "${VAULT_TOKEN}" "bookinfo/replication" \
  "tls.crt=${TMP_CERT_DIR}/tls.crt" \
  "tls.key=${TMP_CERT_DIR}/tls.key" \
  "ca.crt=${TMP_CERT_DIR}/ca.crt"

wait_until "Site B replication TLS secret from ESO" 1800 \
  secret_exists "${SITE_B_CLUSTER}" bookinfo bookinfo-db-replication
wait_until "Site B replication CA secret from ESO" 1800 \
  secret_exists "${SITE_B_CLUSTER}" bookinfo bookinfo-db-ca

log "Waiting for the Site A Service Interconnect AccessGrant"
wait_until "Site A AccessGrant has URL, code and CA" 1800 \
  bash -c '
    json="$(oc --kubeconfig "$1" -n bookinfo get accessgrant grant-cluster-pwv6d -o json 2>/dev/null)" || exit 1
    python3 -c '"'"'
import json,sys
s=json.load(sys.stdin).get("status",{})
raise SystemExit(0 if s.get("url") and s.get("code") and s.get("ca") else 1)
'"'"' <<<"$json"
  ' _ "${SITE_A_KUBECONFIG}"

ACCESS_GRANT_JSON="$(
  site_oc "${SITE_A_CLUSTER}" -n bookinfo \
    get accessgrant grant-cluster-pwv6d -o json
)"

TOKEN_URL="$(
  python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["url"])' \
    <<<"${ACCESS_GRANT_JSON}"
)"
TOKEN_CODE="$(
  python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["code"])' \
    <<<"${ACCESS_GRANT_JSON}"
)"
python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["ca"])' \
  <<<"${ACCESS_GRANT_JSON}" > "${WORK_DIR}/service-interconnect-ca.crt"

log "Storing Service Interconnect token fields in Site B Vault"
vault_put_files "${SITE_B_CLUSTER}" "${VAULT_TOKEN}" "service-interconnect/link" \
  "ca=${WORK_DIR}/service-interconnect-ca.crt"
vault_put_literals "${SITE_B_CLUSTER}" "${VAULT_TOKEN}" "service-interconnect/link-metadata" \
  url="${TOKEN_URL}" \
  code="${TOKEN_CODE}"

wait_until "Site B Service Interconnect CA secret from ESO" 1800 \
  secret_exists "${SITE_B_CLUSTER}" bookinfo service-interconnect-token-ca
wait_until "Site B Service Interconnect metadata secret from ESO" 1800 \
  secret_exists "${SITE_B_CLUSTER}" bookinfo service-interconnect-token-metadata

log "Waiting for Service Interconnect link"
wait_until "Site B link is Ready" 1800 \
  skupper_link_ready "${SITE_B_CLUSTER}"

log "Waiting for Site B PostgreSQL replica"
wait_until "Site B CloudNativePG replica is Ready" 5400 \
  cnpg_ready "${SITE_B_CLUSTER}" bookinfo-db-replica

log "Waiting for Bookinfo"
for cluster in "${SITE_A_CLUSTER}" "${SITE_B_CLUSTER}"; do
  site_oc "${cluster}" -n bookinfo rollout status deployment/details-v1 --timeout=20m
  site_oc "${cluster}" -n bookinfo rollout status deployment/ratings-v1 --timeout=20m
  site_oc "${cluster}" -n bookinfo rollout status deployment/reviews-v1 --timeout=20m
  site_oc "${cluster}" -n bookinfo rollout status deployment/productpage --timeout=20m
done

log "Running final verification"
"${ROOT_DIR}/scripts/test-demo.sh"

cat <<EOF

Deployment complete.

Site A:
  RHACM cluster: ${SITE_A_CLUSTER}
  Bookinfo route: https://$(site_oc "${SITE_A_CLUSTER}" -n bookinfo get route bookinfo -o jsonpath='{.spec.host}')

Site B:
  RHACM cluster: ${SITE_B_CLUSTER}
  Bookinfo route: https://$(site_oc "${SITE_B_CLUSTER}" -n bookinfo get route bookinfo -o jsonpath='{.spec.host}')

Generated credentials:
  ${DEMO_ENV}
EOF
