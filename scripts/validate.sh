#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.work"
VENV_DIR="${WORK_DIR}/validate-venv"
PYTHON_BIN="${VENV_DIR}/bin/python"

command -v python3 >/dev/null 2>&1 || {
  echo "[ERROR] python3 is required." >&2
  exit 1
}

mkdir -p "${WORK_DIR}"

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "[INFO] Creating local Python validation environment: ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi

if ! "${PYTHON_BIN}" -c 'import yaml' >/dev/null 2>&1; then
  echo "[INFO] Installing PyYAML into the local validation environment"
  "${PYTHON_BIN}" -m pip install --quiet --upgrade pip
  "${PYTHON_BIN}" -m pip install --quiet 'PyYAML>=6.0,<7.0'
fi

"${PYTHON_BIN}" - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
errors = []

for path in sorted(root.rglob("*.yaml")):
    if ".work" in path.parts:
        continue
    if path.name.endswith(".yaml.tpl"):
        continue
    try:
        list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    except Exception as exc:
        errors.append(f"{path.relative_to(root)}: {exc}")

template_path = root / "hub/gitops/applicationset.yaml.tpl"
if template_path.exists():
    try:
        rendered = (
            template_path.read_text(encoding="utf-8")
            .replace("__REPO_URL__", "https://github.com/example/repository.git")
            .replace("__REVISION__", "main")
        )
        list(yaml.safe_load_all(rendered))
    except Exception as exc:
        errors.append(
            f"{template_path.relative_to(root)} after rendering: {exc}"
        )

for path in sorted(root.rglob("kustomization.yaml")):
    if ".work" in path.parts:
        continue
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as exc:
        errors.append(f"{path.relative_to(root)}: {exc}")
        continue

    for resource in doc.get("resources", []):
        target = (path.parent / resource).resolve()
        if not target.exists():
            errors.append(
                f"{path.relative_to(root)} references missing resource: {resource}"
            )

if errors:
    print("[ERROR] Repository validation failed:")
    for error in errors:
        print(f"  - {error}")
    raise SystemExit(1)

print("[OK] All YAML files parsed successfully.")
print("[OK] The ApplicationSet template rendered successfully.")
print("[OK] All Kustomize resource references exist.")
PY

for script in \
  "${ROOT_DIR}/bootstrap.sh" \
  "${ROOT_DIR}/verify.sh" \
  "${ROOT_DIR}/cleanup.sh" \
  "${ROOT_DIR}"/scripts/*.sh
do
  bash -n "${script}"
done

echo "[OK] All shell scripts passed Bash syntax validation."
echo "[OK] Repository validation completed successfully."
