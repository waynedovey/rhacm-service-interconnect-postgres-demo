#!/usr/bin/env bash
set -euo pipefail

SITE_A_CLUSTER="${SITE_A_CLUSTER:-cluster-pwv6d}"
NAMESPACE="${NAMESPACE:-bookinfo}"
DATABASE="${DATABASE:-bookinfo}"
APP_ROLE="${APP_ROLE:-bookinfo}"

KUBECONFIG_FILE="${A_KUBECONFIG:-.work/kubeconfigs/${SITE_A_CLUSTER}.kubeconfig}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "[ERROR] Site A kubeconfig not found: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

PRIMARY_POD="$(
  oc --kubeconfig "${KUBECONFIG_FILE}" \
    get pods \
    -n "${NAMESPACE}" \
    -l cnpg.io/cluster=bookinfo-db,role=primary \
    -o jsonpath='{.items[0].metadata.name}'
)"

if [[ -z "${PRIMARY_POD}" ]]; then
  echo "[ERROR] Could not locate the Site A PostgreSQL primary" >&2
  exit 1
fi

echo "[INFO] Applying heartbeat ownership and privileges through ${PRIMARY_POD}"

oc --kubeconfig "${KUBECONFIG_FILE}" \
  exec -i \
  -n "${NAMESPACE}" \
  "${PRIMARY_POD}" \
  -c postgres -- \
  psql \
    -U postgres \
    -d "${DATABASE}" \
    -v ON_ERROR_STOP=1 \
    -v app_role="${APP_ROLE}" <<'SQL'
CREATE TABLE IF NOT EXISTS public.site_heartbeats (
    id BIGSERIAL PRIMARY KEY,
    site TEXT NOT NULL,
    pod TEXT NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.site_heartbeats OWNER TO bookinfo;
ALTER SEQUENCE public.site_heartbeats_id_seq OWNER TO bookinfo;

GRANT USAGE ON SCHEMA public TO bookinfo;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.site_heartbeats
TO bookinfo;

GRANT USAGE, SELECT, UPDATE
ON SEQUENCE public.site_heartbeats_id_seq
TO bookinfo;
SQL

echo "[OK] Heartbeat table and sequence permissions are correct"
