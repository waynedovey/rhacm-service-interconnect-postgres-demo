#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.work"
KUBECONFIG_DIR="${WORK_DIR}/kubeconfigs"

SITE_A_CLUSTER="cluster-pwv6d"
SITE_B_CLUSTER="cluster-7b6lh"

mkdir -p "${KUBECONFIG_DIR}"

log() {
  printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_until() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2

  local start now
  start="$(date +%s)"

  while true; do
    if "$@" >/dev/null 2>&1; then
      ok "${description}"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      die "Timed out waiting for: ${description}"
    fi

    sleep 10
  done
}

managed_cluster_available() {
  local cluster="$1"
  oc get managedcluster "${cluster}" -o json |
    python3 -c '
import json, sys
obj=json.load(sys.stdin)
for c in obj.get("status",{}).get("conditions",[]):
    if c.get("type")=="ManagedClusterConditionAvailable" and c.get("status")=="True":
        raise SystemExit(0)
raise SystemExit(1)
'
}

policy_compliant() {
  local policy="$1"
  [[ "$(oc -n si-demo-policies get policy "${policy}" -o jsonpath='{.status.compliant}' 2>/dev/null)" == "Compliant" ]]
}

get_cluster_kubeconfig() {
  local cluster="$1"
  local output="${KUBECONFIG_DIR}/${cluster}.kubeconfig"
  local secret="${cluster}-admin-kubeconfig"

  if [[ -s "${output}" ]]; then
    printf '%s\n' "${output}"
    return 0
  fi

  wait_until \
    "Hive admin kubeconfig for ${cluster}" \
    1800 \
    oc -n "${cluster}" get secret "${secret}" >&2

  oc -n "${cluster}" get secret "${secret}" -o json |
    python3 -c '
import base64, json, sys
obj=json.load(sys.stdin)
value=obj["data"]["kubeconfig"]
sys.stdout.buffer.write(base64.b64decode(value))
' > "${output}"

  chmod 600 "${output}"
  printf '%s\n' "${output}"
}

site_oc() {
  local cluster="$1"
  shift
  local kubeconfig
  kubeconfig="$(get_cluster_kubeconfig "${cluster}")"
  oc --kubeconfig "${kubeconfig}" "$@"
}

cluster_crd_exists() {
  local cluster="$1"
  local crd="$2"
  site_oc "${cluster}" get crd "${crd}"
}

secret_exists() {
  local cluster="$1"
  local namespace="$2"
  local secret="$3"
  site_oc "${cluster}" -n "${namespace}" get secret "${secret}"
}

cnpg_ready() {
  local cluster="$1"
  local name="$2"
  site_oc "${cluster}" -n bookinfo get cluster.postgresql.cnpg.io "${name}" -o json |
    python3 -c '
import json, sys
obj=json.load(sys.stdin)
for c in obj.get("status",{}).get("conditions",[]):
    if c.get("type")=="Ready" and c.get("status")=="True":
        raise SystemExit(0)
raise SystemExit(1)
'
}

skupper_link_ready() {
  local cluster="$1"
  site_oc "${cluster}" -n bookinfo get link -o json |
    python3 -c '
import json, sys
obj=json.load(sys.stdin)
for item in obj.get("items",[]):
    status=item.get("status",{})
    if status.get("status")=="Ready" or status.get("state")=="Ready":
        raise SystemExit(0)
    for c in status.get("conditions",[]):
        if c.get("type")=="Ready" and c.get("status")=="True":
            raise SystemExit(0)
raise SystemExit(1)
'
}

get_secret_key() {
  local cluster="$1"
  local namespace="$2"
  local secret="$3"
  local key="$4"

  site_oc "${cluster}" -n "${namespace}" get secret "${secret}" -o json |
    python3 -c '
import base64, json, sys
key=sys.argv[1]
obj=json.load(sys.stdin)
value=obj["data"][key]
sys.stdout.buffer.write(base64.b64decode(value))
' "${key}"
}

vault_pod() {
  local cluster="$1"
  site_oc "${cluster}" -n vault-demo get pods \
    -l app.kubernetes.io/name=vault-demo \
    -o jsonpath='{.items[0].metadata.name}'
}

vault_put_literals() {
  local cluster="$1"
  local token="$2"
  local path="$3"
  shift 3

  local pod
  pod="$(vault_pod "${cluster}")"

  site_oc "${cluster}" -n vault-demo exec "${pod}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${token}" \
    vault kv put "secret/${path}" "$@"
}

vault_put_files() {
  local cluster="$1"
  local token="$2"
  local path="$3"
  shift 3

  local pod
  pod="$(vault_pod "${cluster}")"

  local args=()
  local pair key file remote
  for pair in "$@"; do
    key="${pair%%=*}"
    file="${pair#*=}"
    remote="/tmp/${key//./-}"
    site_oc "${cluster}" -n vault-demo cp "${file}" "${pod}:${remote}"
    args+=("${key}=@${remote}")
  done

  site_oc "${cluster}" -n vault-demo exec "${pod}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${token}" \
    vault kv put "secret/${path}" "${args[@]}"
}
