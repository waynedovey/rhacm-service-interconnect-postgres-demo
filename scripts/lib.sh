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

placement_has_cluster() {
  local namespace="$1"
  local placement="$2"
  local cluster="$3"

  oc -n "${namespace}" get placementdecision \
    -l "cluster.open-cluster-management.io/placement=${placement}" \
    -o json 2>/dev/null |
    python3 -c '
import json, sys
cluster=sys.argv[1]
obj=json.load(sys.stdin)
for item in obj.get("items", []):
    for decision in item.get("status", {}).get("decisions", []):
        if decision.get("clusterName") == cluster:
            raise SystemExit(0)
raise SystemExit(1)
' "${cluster}"
}

show_placement_decisions() {
  local namespace="$1"
  oc -n "${namespace}" get placementdecision \
    -o custom-columns='NAME:.metadata.name,PLACEMENT:.metadata.labels.cluster\.open-cluster-management\.io/placement,CLUSTERS:.status.decisions[*].clusterName' \
    2>/dev/null || true
}

get_cluster_kubeconfig() {
  local cluster="$1"
  local output="${KUBECONFIG_DIR}/${cluster}.kubeconfig"
  local temp_output="${output}.tmp"
  local secret=""
  local start now last_message=0

  # Reuse only a kubeconfig that is both syntactically plausible and usable.
  if [[ -s "${output}" ]]; then
    if head -n 5 "${output}" | grep -q '^apiVersion:' &&
       oc --kubeconfig "${output}" whoami >/dev/null 2>&1; then
      printf '%s
' "${output}"
      return 0
    fi

    warn "Removing invalid cached kubeconfig: ${output}"
    rm -f "${output}"
  fi

  printf '[INFO] Discovering Hive admin kubeconfig for %s
' \
    "${cluster}" >&2

  start="$(date +%s)"

  while true; do
    # Hive records the real Secret name here after installation.
    secret="$(
      oc -n "${cluster}" get clusterdeployment "${cluster}" \
        -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' \
        2>/dev/null || true
    )"

    if [[ -n "${secret}" ]] &&
       oc -n "${cluster}" get secret "${secret}" >/dev/null 2>&1; then
      break
    fi

    now="$(date +%s)"
    if (( now - start >= 1800 )); then
      printf '
[ERROR] Timed out waiting for Hive admin kubeconfig for %s.
' \
        "${cluster}" >&2
      printf '[INFO] ClusterDeployment status:
' >&2
      oc -n "${cluster}" get clusterdeployment "${cluster}" -o yaml >&2 || true
      printf '[INFO] Kubeconfig-related Secrets:
' >&2
      oc -n "${cluster}" get secrets |
        grep -Ei 'kubeconfig|admin' >&2 || true
      return 1
    fi

    if (( now - last_message >= 30 )); then
      printf '[INFO] %s: waiting for ClusterDeployment adminKubeconfigSecretRef' \
        "${cluster}" >&2
      if [[ -n "${secret}" ]]; then
        printf ' (referenced Secret: %s)' "${secret}" >&2
      fi
      printf '
' >&2
      last_message="${now}"
    fi

    sleep 10
  done

  printf '[INFO] %s: extracting Secret %s
' \
    "${cluster}" "${secret}" >&2

  rm -f "${temp_output}"

  # Decode the Secret directly instead of using `oc extract --to=-`.
  # Depending on the oc version, `oc extract` can emit an extraction header.
  # Hive normally provides `kubeconfig`; `raw-kubeconfig` is used as a fallback.
  oc -n "${cluster}" get secret "${secret}" -o json |
    python3 -c '
import base64
import json
import sys

obj = json.load(sys.stdin)
data = obj.get("data", {})

value = data.get("kubeconfig") or data.get("raw-kubeconfig")
if not value:
    available = ", ".join(sorted(data.keys())) or "<none>"
    print(
        f"Secret does not contain kubeconfig or raw-kubeconfig. "
        f"Available keys: {available}",
        file=sys.stderr,
    )
    raise SystemExit(1)

try:
    decoded = base64.b64decode(value, validate=True)
except Exception as exc:
    print(f"Unable to decode kubeconfig Secret data: {exc}", file=sys.stderr)
    raise SystemExit(1)

sys.stdout.buffer.write(decoded)
' > "${temp_output}"

  chmod 600 "${temp_output}"

  if [[ ! -s "${temp_output}" ]]; then
    rm -f "${temp_output}"
    die "The decoded ${cluster} kubeconfig is empty"
  fi

  if ! oc --kubeconfig "${temp_output}" config view --raw \
    >/dev/null 2>&1; then
    printf '[ERROR] First lines of the decoded kubeconfig:\n' >&2
    sed -n '1,12p' "${temp_output}" >&2 || true
    rm -f "${temp_output}"
    die "The decoded ${cluster} kubeconfig is not a valid kubeconfig"
  fi

  if ! oc --kubeconfig "${temp_output}" whoami >/dev/null 2>&1; then
    printf '[INFO] API endpoint from decoded kubeconfig:\n' >&2
    oc --kubeconfig "${temp_output}" config view \
      -o jsonpath='{.clusters[0].cluster.server}{"\n"}' >&2 || true
    rm -f "${temp_output}"
    die "The decoded ${cluster} kubeconfig cannot authenticate to the cluster"
  fi

  mv "${temp_output}" "${output}"

  printf '[OK] %s admin kubeconfig is usable
' "${cluster}" >&2
  printf '%s
' "${output}"
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
