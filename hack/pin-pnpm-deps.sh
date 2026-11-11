#!/usr/bin/env bash
# Patch pnpm lockfiles and package.json files to replace remote GitHub URLs
# with local file:// paths.
#
# This script enables hermetic builds by replacing remote argo-ui dependencies
# with references to locally-pinned sources. It runs as part of sync_ui_refs after has
# fetched the submodules.

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

# Sync pnpm.overrides from a pnpm-lock.yaml into a package.json.
# pnpm --frozen-lockfile fails with ERR_PNPM_LOCKFILE_CONFIG_MISMATCH when the
# lockfile declares overrides that package.json does not.  This can happen when
# upstream removes pnpm.overrides from package.json without regenerating the
# lockfile.  Call this after stage_overlay_file for every package.json overlay
# to keep the two files consistent.
#
# Arguments:
#   $1 - lockfile: pnpm-lock.yaml whose overrides section is authoritative
#   $2 - pkg:      package.json to patch in place
sync_lockfile_overrides() {
  local lockfile=$1
  local pkg=$2

  local tmp
  tmp=$(mktemp "${pkg}.XXXXXX")

  python3 - "$lockfile" "$pkg" "$tmp" <<'PYEOF'
import json, re, sys

lockfile_path, pkg_path, tmp_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(lockfile_path) as f:
    content = f.read()

# Parse the top-level overrides block.  The format is strict YAML produced by
# pnpm itself:  "overrides:\n  'key': value\n  key: value\n"
overrides = {}
m = re.search(r'^overrides:\n((?:  [^\n]+\n?)*)', content, re.MULTILINE)
if m:
    for line in m.group(1).splitlines():
        if ':' in line:
            k, v = line.strip().split(':', 1)
            overrides[k.strip().strip("'")] = v.strip().strip("'")

if not overrides:
    sys.exit(2)  # no overrides in lockfile — nothing to do

with open(pkg_path) as f:
    data = json.load(f)

existing = data.get('pnpm', {}).get('overrides', {})
if existing == overrides:
    sys.exit(2)  # already in sync

data.setdefault('pnpm', {})['overrides'] = overrides

with open(tmp_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF

  local ec=$?
  if [[ $ec -eq 2 ]]; then
    rm -f "$tmp"
    echo "- $pkg pnpm.overrides already matches lockfile"
  elif [[ $ec -eq 0 ]]; then
    mv "$tmp" "$pkg"
    echo "✓ Synced pnpm.overrides from $lockfile into $pkg"
  else
    rm -f "$tmp"
    return $ec
  fi
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
