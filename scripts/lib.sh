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
    if oc --kubeconfig "${output}" config view --raw >/dev/null 2>&1 &&
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
        f"Secret contains neither kubeconfig nor raw-kubeconfig. "
        f"Available keys: {available}",
        file=sys.stderr,
    )
    raise SystemExit(1)

sys.stdout.buffer.write(base64.b64decode(value, validate=True))
' > "${temp_output}"

  chmod 600 "${temp_output}"

  if [[ ! -s "${temp_output}" ]] ||
     ! oc --kubeconfig "${temp_output}" config view --raw >/dev/null 2>&1; then
    rm -f "${temp_output}"
    die "The decoded ${cluster} admin kubeconfig is invalid"
  fi

  if ! oc --kubeconfig "${temp_output}" whoami >/dev/null 2>&1; then
    rm -f "${temp_output}"
    die "The decoded ${cluster} admin kubeconfig cannot authenticate"
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

operator_catalog_has_channel() {
  local cluster="$1"
  local package="$2"
  local source="$3"
  local channel="$4"

  site_oc "${cluster}" -n openshift-marketplace \
    get packagemanifest "${package}" -o json 2>/dev/null |
    python3 -c '
import json
import sys

source = sys.argv[1]
channel = sys.argv[2]
obj = json.load(sys.stdin)
status = obj.get("status", {})

if status.get("catalogSource") != source:
    raise SystemExit(1)

channels = {
    entry.get("name")
    for entry in status.get("channels", [])
}
raise SystemExit(0 if channel in channels else 1)
' "${source}" "${channel}"
}

show_operator_catalog() {
  local cluster="$1"
  local package="$2"

  site_oc "${cluster}" -n openshift-marketplace \
    get packagemanifest "${package}" \
    -o json 2>/dev/null |
    python3 -c '
import json
import sys

obj = json.load(sys.stdin)
status = obj.get("status", {})
channels = [
    entry.get("name")
    for entry in status.get("channels", [])
    if entry.get("name")
]

print(
    "package={package} source={source} defaultChannel={default} channels={channels}".format(
        package=obj.get("metadata", {}).get("name", "<unknown>"),
        source=status.get("catalogSource", "<unknown>"),
        default=status.get("defaultChannel", "<none>"),
        channels=",".join(channels) or "<none>",
    )
)
' || true
}

wait_for_olm_subscription() {
  local cluster="$1"
  local namespace="$2"
  local subscription="$3"
  local expected_package="$4"
  local expected_source="$5"
  local expected_channel="$6"
  local timeout_seconds="${7:-1800}"

  local start now last_message=0
  local payload
  start="$(date +%s)"

  while true; do
    payload="$(
      site_oc "${cluster}" -n "${namespace}" \
        get subscriptions.operators.coreos.com "${subscription}" \
        -o json 2>/dev/null || true
    )"

    if [[ -n "${payload}" ]]; then
      if python3 - "${expected_package}" "${expected_source}" \
        "${expected_channel}" <<<"${payload}" <<'PY'
import json
import sys

expected_package, expected_source, expected_channel = sys.argv[1:]
obj = json.load(sys.stdin)
spec = obj.get("spec", {})

if spec.get("name") != expected_package:
    raise SystemExit(2)
if spec.get("source") != expected_source:
    raise SystemExit(3)
if spec.get("channel") != expected_channel:
    raise SystemExit(4)

status = obj.get("status", {})
raise SystemExit(0 if status.get("installedCSV") else 1)
PY
      then
        local installed_csv
        installed_csv="$(
          python3 -c '
import json
import sys
print(json.load(sys.stdin).get("status", {}).get("installedCSV", ""))
' <<<"${payload}"
        )"
        ok "${cluster}: ${subscription} installed as ${installed_csv}"
        return 0
      else
        local rc=$?
        case "${rc}" in
          2|3|4)
            printf '[ERROR] %s: Subscription %s has the wrong package, source, or channel.\n' \
              "${cluster}" "${subscription}" >&2
            site_oc "${cluster}" -n "${namespace}" \
              get subscriptions.operators.coreos.com "${subscription}" \
              -o custom-columns='NAME:.metadata.name,PACKAGE:.spec.name,SOURCE:.spec.source,CHANNEL:.spec.channel,STATE:.status.state,CURRENT:.status.currentCSV,INSTALLED:.status.installedCSV' \
              >&2 || true
            show_operator_catalog "${cluster}" "${expected_package}" >&2
            return 1
            ;;
        esac
      fi
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      printf '[ERROR] Timed out waiting for OLM Subscription %s on %s.\n' \
        "${subscription}" "${cluster}" >&2

      site_oc "${cluster}" -n "${namespace}" \
        get subscriptions.operators.coreos.com "${subscription}" \
        -o yaml >&2 || true

      site_oc "${cluster}" -n "${namespace}" \
        get installplans.operators.coreos.com >&2 || true

      show_operator_catalog "${cluster}" "${expected_package}" >&2
      return 1
    fi

    if (( now - last_message >= 30 )); then
      printf '[INFO] %s: waiting for %s (%s/%s)\n' \
        "${cluster}" "${subscription}" \
        "${expected_source}" "${expected_channel}" >&2

      if [[ -n "${payload}" ]]; then
        python3 -c '
import json
import sys

obj = json.load(sys.stdin)
status = obj.get("status", {})
conditions = status.get("conditions", [])

print(
    "  state={state} currentCSV={current} installedCSV={installed}".format(
        state=status.get("state", "<none>"),
        current=status.get("currentCSV", "<none>"),
        installed=status.get("installedCSV", "<none>"),
    ),
    file=sys.stderr,
)

for condition in conditions:
    print(
        "  condition type={type} status={status} reason={reason} message={message}".format(
            type=condition.get("type", ""),
            status=condition.get("status", ""),
            reason=condition.get("reason", ""),
            message=condition.get("message", ""),
        ),
        file=sys.stderr,
    )
' <<<"${payload}"
      fi

      last_message="${now}"
    fi

    sleep 10
  done
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
