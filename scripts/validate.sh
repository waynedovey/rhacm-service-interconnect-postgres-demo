#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
errors = []

for path in sorted(root.rglob("*.yaml")):
    if path.name.endswith(".yaml.tpl"):
        continue
    try:
        list(yaml.safe_load_all(path.read_text()))
    except Exception as exc:
        errors.append(f"{path.relative_to(root)}: {exc}")

for path in sorted(root.rglob("kustomization.yaml")):
    doc = yaml.safe_load(path.read_text())
    for resource in doc.get("resources", []):
        target = (path.parent / resource).resolve()
        if not target.exists():
            errors.append(f"{path.relative_to(root)} references missing {resource}")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)

print("All YAML files parsed and all Kustomize resource references exist.")
PY

for script in \
  "${ROOT_DIR}/bootstrap.sh" \
  "${ROOT_DIR}/verify.sh" \
  "${ROOT_DIR}/cleanup.sh" \
  "${ROOT_DIR}"/scripts/*.sh
do
  bash -n "${script}"
done

echo "All shell scripts passed bash syntax validation."
