#!/usr/bin/env bash
set -euo pipefail

pin_lockfile() {
  local src=$1
  local dst=$2
  local pin=$3
  local file_spec=$4

  if [[ ! -f "$src" ]]; then
    echo ">>> $src not found. Run 'make sources' first."
    exit 1
  fi

  echo ">>> Refreshing $dst from $src"
  # Replace a symlink or previous overlay file so we never write through into the submodule.
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst"
  cp "$src" "$dst"

  if command -v node >/dev/null 2>&1; then
    node "$pin" "$dst"
  else
    echo ">>> node not found; pinning lockfile with python3"
    python3 - "$dst" "$file_spec" <<'PY'
import re
import sys

path = sys.argv[1]
file_spec = sys.argv[2]
directory = file_spec[5:] if file_spec.startswith("file:") else file_spec
file_resolution = (
    f"resolution: {{directory: {directory}, type: directory, "
    f"tarball: {file_spec}}}"
)
git_spec = re.compile(r"git\+https://github\.com/argoproj/argo-ui\.git#[0-9a-f]+")
tarball = re.compile(r"https://codeload\.github\.com/argoproj/argo-ui/tar\.gz/[0-9a-f]+")
resolution = re.compile(
    r"resolution: \{tarball: https://codeload\.github\.com/argoproj/argo-ui/tar\.gz/[0-9a-f]+\}"
)
original = open(path, encoding="utf-8").read()
if not git_spec.search(original) and not tarball.search(original):
    if file_spec not in original:
        raise SystemExit(f"{path} has no argo-ui git/tarball reference to pin")
    raise SystemExit(0)
pinned = git_spec.sub(file_spec, original)
pinned = resolution.sub(file_resolution, pinned)
pinned = tarball.sub(file_spec, pinned)
open(path, "w", encoding="utf-8").write(pinned)
PY
  fi

  echo ">>> Pinned argo-ui to $file_spec"
}

pin_lockfile \
  sources/argo-rollouts/ui/pnpm-lock.yaml \
  clis/kubectl-argo-rollouts/ui/pnpm-lock.yaml \
  clis/kubectl-argo-rollouts/ui/pin-argo-ui.js \
  "file:../../../sources/argo-ui"

pin_lockfile \
  sources/argo-cd/ui/pnpm-lock.yaml \
  containers/argocd/ui/pnpm-lock.yaml \
  containers/argocd/ui/pin-argo-ui.js \
  "file:../../../sources/argo-ui-cd"
