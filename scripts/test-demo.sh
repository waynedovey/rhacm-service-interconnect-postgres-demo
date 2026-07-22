#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

query_from_productpage() {
  local cluster="$1"
  local connection="$2"
  local pod

  pod="$(
    site_oc "${cluster}" -n bookinfo get pods \
      -l app=productpage \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  site_oc "${cluster}" -n bookinfo exec "${pod}" -c db-heartbeat -- \
    bash -ec "
      export PGPASSWORD=\"\${POSTGRES_PASSWORD}\"
      psql \"${connection}\" \
        -v ON_ERROR_STOP=1 \
        -c \"SELECT site, count(*) AS heartbeats, max(observed_at) AS latest FROM site_heartbeats GROUP BY site ORDER BY site;\"
    "
}

log "Service Interconnect status"
site_oc "${SITE_A_CLUSTER}" -n bookinfo get site,accessgrant,connector,listener
site_oc "${SITE_B_CLUSTER}" -n bookinfo get site,accesstoken,link,connector,listener

log "CloudNativePG status"
site_oc "${SITE_A_CLUSTER}" -n bookinfo get cluster.postgresql.cnpg.io
site_oc "${SITE_B_CLUSTER}" -n bookinfo get cluster.postgresql.cnpg.io

log "Rows visible through the writable multi-host connection"
query_from_productpage "${SITE_A_CLUSTER}" \
  "host=postgres-site-a,postgres-site-b port=5432,5432 dbname=bookinfo user=bookinfo target_session_attrs=read-write connect_timeout=5"

log "Rows visible directly on the Site B read-only replica"
query_from_productpage "${SITE_B_CLUSTER}" \
  "host=postgres-site-b port=5432 dbname=bookinfo user=bookinfo target_session_attrs=any connect_timeout=5"

log "Bookinfo routes"
printf 'Site A: https://%s\n' \
  "$(site_oc "${SITE_A_CLUSTER}" -n bookinfo get route bookinfo -o jsonpath='{.spec.host}')"
printf 'Site B: https://%s\n' \
  "$(site_oc "${SITE_B_CLUSTER}" -n bookinfo get route bookinfo -o jsonpath='{.spec.host}')"
