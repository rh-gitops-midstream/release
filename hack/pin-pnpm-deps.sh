#!/usr/bin/env bash
set -euo pipefail

# Copy UI lockfiles out of submodules and rewrite the argo-ui GitHub pin to a
# local file: path so Hermeto does not fetch GitHub.
#
# Argo Rollouts and Argo CD pin different argo-ui commits, so each overlay
# points at its own submodule (sources/argo-rollouts-ui-ref vs sources/argo-cd-ui-ref).

GIT_SPEC='git\+https://github\.com/argoproj/argo-ui\.git#[0-9a-f]+'
TARBALL='https://codeload\.github\.com/argoproj/argo-ui/tar\.gz/[0-9a-f]+'

pin_lockfile() {
  local src=$1
  local dst=$2
  local file_spec=$3
  local directory=${file_spec#file:}
  local resolution="resolution: {directory: ${directory}, type: directory, tarball: ${file_spec}}"

  if [[ ! -f "$src" ]]; then
    echo ">>> $src not found. Run 'make sources' first."
    exit 1
  fi

  echo ">>> Refreshing $dst from $src"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst" # never write through a symlink into the submodule

  # Order matters: rewrite the resolution object before remaining tarball URLs.
  sed -E \
    -e "s|${GIT_SPEC}|${file_spec}|g" \
    -e "s|resolution: \{tarball: ${TARBALL}\}|${resolution}|g" \
    -e "s|${TARBALL}|${file_spec}|g" \
    "$src" > "$dst"

  if ! grep -qF "$file_spec" "$dst"; then
    echo ">>> $dst has no argo-ui git/tarball reference to pin"
    exit 1
  fi

  echo ">>> Pinned argo-ui to $file_spec"
}

pin_lockfile \
  sources/argo-rollouts/ui/pnpm-lock.yaml \
  clis/kubectl-argo-rollouts/ui/pnpm-lock.yaml \
  "file:../../../sources/argo-rollouts-ui-ref"

pin_lockfile \
  sources/argo-cd/ui/pnpm-lock.yaml \
  containers/argocd/ui/pnpm-lock.yaml \
  "file:../../../sources/argo-cd-ui-ref"
