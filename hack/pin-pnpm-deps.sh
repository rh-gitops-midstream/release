#!/usr/bin/env bash
# Patch pnpm lockfiles and package.json files to replace remote GitHub URLs
# with local file:// paths.
#
# This script enables hermetic builds by replacing remote argo-ui dependencies
# with references to locally-pinned sources. It runs after `make sources` has
# fetched the submodules and is called before container image builds.

set -euo pipefail

#
# Regular expressions matching argo-ui remote URLs in pnpm files
# (package.json / pnpm-lock.yaml).
#
# Matches the git+https dependency spec pnpm writes for a GitHub-pinned
# dependency, e.g.:
#   git+https://github.com/argoproj/argo-ui.git#1234567890abcdef1234567890abcdef12345678
readonly ARGO_UI_GIT_SPEC_PATTERN='git\+https://github\.com/argoproj/argo-ui\.git#[0-9a-f]{40}'

# Matches the GitHub codeload tarball URL pnpm resolves the above spec to in
# pnpm-lock.yaml, e.g.:
#   https://codeload.github.com/argoproj/argo-ui/tar.gz/1234567890abcdef1234567890abcdef12345678
readonly ARGO_UI_TARBALL_PATTERN='https://codeload\.github\.com/argoproj/argo-ui/tar\.gz/[0-9a-f]{40}'

GIT_SPEC="${ARGO_UI_GIT_SPEC_PATTERN}"
TARBALL="${ARGO_UI_TARBALL_PATTERN}"

# Patch any file in place: replace remote argo-ui GitHub/tarball URLs with a
# local file:// path.
# Arguments:
#   $1 - file: path to patch in place (e.g., containers/argocd/ui/pnpm-lock.yaml,
#        or just pnpm-lock.yaml when called against the Docker build's WORKDIR)
#   $2 - file_spec: local file:// path to redirect to (e.g., file:../../../sources/argo-cd-ui-ref)
#
# Side effects:
#   - Validates that file exists; exits if missing
#   - No-ops if file already contains file_spec (idempotent)
#   - Validates that at least one remote URL pattern is present before writing; exits if none found
#   - Rewrites file atomically via a same-directory temp file + mv
pin_ui_deps_to_local_file() {
  local file=$1
  local file_spec=$2

  if [[ ! -f "$file" ]]; then
    echo "✗ $file not found. Run 'make sources' first." >&2
    exit 1
  fi

  # Already pinned -- nothing to do.
  if grep -qF "$file_spec" "$file"; then
    echo "- $file is already pinned to local sources"
    return
  fi

  # Validate that at least one remote URL pattern is present before writing.
  if ! grep -Eq "${GIT_SPEC}|${TARBALL}" "$file"; then
    echo "✗ $file has no argo-ui reference to pin. Check that this is the correct file for an Argo product." >&2
    exit 1
  fi

  # Construct the pnpm resolution block for the local directory reference,
  # derived entirely from file_spec (pnpm resolution objects have the form
  # {directory: <path>, type: directory, tarball: file:<path>}).
  local directory=${file_spec#file:}
  local resolution="resolution: {directory: ${directory}, type: directory, tarball: ${file_spec}}"

  # Replace all three URL patterns atomically:
  #   1. resolution: {...tarball: TARBALL_URL...} → resolution: {directory: ..., type: directory, tarball: file:...}
  #   2. git+https://... → file:...
  #   3. https://codeload.github.com/... → file:...
  # Order matters: resolution blocks must be rewritten first (they are the most specific match).
  # The resolution object may include extra fields before tarball: (e.g., gitHosted, integrity),
  # which are matched by [^}]* and swallowed along with the URL during replacement.
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  sed -E \
    -e "s|resolution: \{[^}]*tarball: ${TARBALL}\}|${resolution}|g" \
    -e "s|${GIT_SPEC}|${file_spec}|g" \
    -e "s|${TARBALL}|${file_spec}|g" \
    "$file" > "$tmp"
  mv "$tmp" "$file"

  echo "✓ Pinned argo-ui to $file_spec in $file"
}

# Stage one overlay file from its pristine submodule copy  and then patch it in
# place via pin_ui_deps_to_local_file.
# Arguments:
#   $1 - src: source file (from the submodule, e.g., sources/argo-cd/ui/pnpm-lock.yaml)
#   $2 - dst: destination overlay file (e.g., containers/argocd/ui/pnpm-lock.yaml)
#   $3 - file_spec: local file:// path to redirect to (e.g., file:../../../sources/argo-cd-ui-ref)
#
# Side effects:
#   - Validates that src exists; exits if missing
#   - Creates parent directories of dst if needed
#   - Overwrites dst as a real file (removes any pre-existing symlink first --
stage_overlay_file() {
  local src=$1
  local dst=$2
  local file_spec=$3

  if [[ ! -f "$src" ]]; then
    echo "✗ $src not found. Run 'make sources' first." >&2
    exit 1
  fi

  echo ">>> Pinning argo-ui dependencies in $dst"
  mkdir -p "$(dirname "$dst")"

  # Delete destination if it exists
  rm -f "$dst"
  cp "$src" "$dst"

  pin_ui_deps_to_local_file "$dst" "$file_spec"
}

stage_overlay_file \
  sources/argo-rollouts/ui/pnpm-lock.yaml \
  clis/kubectl-argo-rollouts/ui/pnpm-lock.yaml \
  "file:../../../sources/argo-rollouts-ui-ref"

stage_overlay_file \
  sources/argo-rollouts/ui/package.json \
  clis/kubectl-argo-rollouts/ui/package.json \
  "file:../../../sources/argo-rollouts-ui-ref"

stage_overlay_file \
  sources/argo-cd/ui/pnpm-lock.yaml \
  containers/argocd/ui/pnpm-lock.yaml \
  "file:../../../sources/argo-cd-ui-ref"

stage_overlay_file \
  sources/argo-cd/ui/package.json \
  containers/argocd/ui/package.json \
  "file:../../../sources/argo-cd-ui-ref"
