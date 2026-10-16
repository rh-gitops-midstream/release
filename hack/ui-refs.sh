#!/usr/bin/env bash
# Sourced by update-sources.sh, sync-sources.sh, and verify-sources.sh.
# The *-ui-ref submodules track the argo-ui commit pinned in the parent product's UI.
# This ensures hermetic builds have deterministic, pinned UI dependencies.

set -euo pipefail

PKG_FILE="ui/package.json"

# Extract a field value from config.yaml for a given source path.
# Queries the YAML structure: .sources[] | select(.path == "${path}") | .${field}
#
# Arguments:
#   $1 - source path (e.g., sources/argo-cd)
#   $2 - field name (e.g., url, commit, ref)
# Output:
#   The field value, or "null" if not found
config_source_field() {
  local path=$1
  local field=$2

  # Use yq to extract the field; suppress errors to return "null" gracefully
  $YQ e ".sources[] | select(.path == \"${path}\") | .${field}" "$CONFIG" 2>/dev/null || echo "null"
}

# Parse and validate the 40-character argo-ui commit hash from package.json.
# The argo-ui dependency in package.json is pinned as:
#   "argo-ui": "github:argoproj/argo-ui#<commit-sha>"
# This function extracts and validates the SHA after the '#' character.
#
# Arguments:
#   $1 - raw package.json contents (string)
# Output:
#   40-character hex commit hash on success
# Exit code:
#   0 if valid hash found, 1 otherwise
argo_ui_sha() {
  local pkg_json=$1
  local dep sha

  # Extract the argo-ui dependency value from JSON
  dep=$($YQ e '.dependencies["argo-ui"]' - <<< "$pkg_json")

  # Remove everything up to and including the '#' to isolate the SHA
  sha=${dep##*#}

  # Validate: SHA must be exactly 40 hexadecimal characters
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$sha"
    return 0
  else
    return 1
  fi
}

# Retrieve the argo-ui commit hash for a specific parent repository and commit.
# Prioritizes the local checkout if present and matches; otherwise fetches
# package.json from GitHub at the specified commit.
#
# Arguments:
#   $1 - parent source path (e.g., sources/argo-cd)
#   $2 - parent commit SHA
#   $3 - parent repository URL
# Output:
#   40-character argo-ui commit hash
# Exit code:
#   0 on success, 1 if unable to retrieve or parse the hash
argo_ui_sha_at_commit() {
  local parent=$1
  local commit=$2
  local url=$3
  local pkg_json repo

  # Check if local checkout is available and already at the expected commit
  if [ -f "$parent/$PKG_FILE" ] && [ "$(git -C "$parent" rev-parse HEAD 2>/dev/null || echo "DETACHED")" = "$commit" ]; then
    # Use local file to avoid network round-trip
    pkg_json=$(cat "$parent/$PKG_FILE")
  else
    # Extract repository name (owner/repo) from full GitHub URL
    repo=${url#https://github.com/}
    repo=${repo%.git}

    # Fetch package.json at the specified commit from GitHub
    if ! pkg_json=$(curl -fsSL "https://raw.githubusercontent.com/${repo}/${commit}/${PKG_FILE}"); then
      echo "✗ Failed to fetch ${PKG_FILE} from ${url} at commit ${commit}" >&2
      return 1
    fi
  fi

  # Extract and validate the argo-ui SHA
  argo_ui_sha "$pkg_json"
}

# Sync (checkout) a *-ui-ref submodule to the argo-ui commit pinned in its parent.
# Queries config.yaml for the parent's URL and commit, derives the argo-ui commit,
# initializes the submodule if needed, and checks out the commit.
#
# Arguments:
#   $1 - ui-ref submodule path (e.g., sources/argo-cd-ui-ref)
#   $2 - parent source path (e.g., sources/argo-cd)
# Exit code:
#   0 on success, 1 on error (returns, not exits, to allow caller to handle)
checkout_ui_ref() {
  local ui_ref=$1
  local parent=$2
  local url commit sha current

  echo ">>> Processing $ui_ref (pinned via $parent/$PKG_FILE)"

  # Query config.yaml for parent's source URL and commit
  url=$(config_source_field "$parent" url)
  commit=$(config_source_field "$parent" commit)

  # Validate that parent source is configured
  if [ -z "$url" ] || [ -z "$commit" ] || [ "$url" = "null" ] || [ "$commit" = "null" ]; then
    echo "✗ Parent source $parent not found in $CONFIG" >&2
    return 1
  fi

  # Derive the argo-ui commit hash from parent's package.json
  if ! sha=$(argo_ui_sha_at_commit "$parent" "$commit" "$url"); then
    echo "✗ Could not read argo-ui git pin from $parent@$commit" >&2
    return 1
  fi

  # Initialize submodule if not already present
  if [ ! -e "$ui_ref/.git" ]; then
    echo ">>> Initializing submodule $ui_ref"
    git submodule update --init "$ui_ref"
  fi

  # Check current commit to avoid unnecessary git operations
  current=$(git -C "$ui_ref" rev-parse HEAD)
  if [ "$current" = "$sha" ]; then
    echo "- $ui_ref already at $sha"
    return 0
  fi

  # Fetch and checkout the target commit
  (
    cd "$ui_ref"
    git fetch origin
    git checkout "$sha"
  )
  echo "✓ Checked out $ui_ref: $current -> $sha"
}

sync_ui_refs() {
  echo ">>> Syncing *-ui-ref checkouts from parent UI package.json"
  checkout_ui_ref sources/argo-cd-ui-ref sources/argo-cd
  checkout_ui_ref sources/argo-rollouts-ui-ref sources/argo-rollouts
}

# Verify that a *-ui-ref submodule is at the commit pinned by its parent.
# Used after checkouts to validate consistency between config.yaml and git refs.
#
# Arguments:
#   $1 - ui-ref submodule path
#   $2 - parent source path
# Side effects:
#   Sets global variable 'errors' to 1 on mismatch (for aggregated error reporting).
#   'errors' is declared and consumed by the sourcing script (verify-sources.sh),
#   not by this file, so shellcheck cannot see the read site.
# shellcheck disable=SC2034
verify_ui_ref() {
  local ui_ref=$1
  local parent=$2
  local sha current_commit

  echo ">>> Verifying $ui_ref"

  # Check that parent's package.json is present
  if [ ! -f "$parent/$PKG_FILE" ]; then
    echo "✗ $parent/$PKG_FILE not found" >&2
    errors=1
    return
  fi

  # Extract argo-ui commit from parent's package.json
  if ! sha=$(argo_ui_sha "$(cat "$parent/$PKG_FILE")"); then
    echo "✗ Could not read argo-ui git pin from $parent/$PKG_FILE" >&2
    errors=1
    return
  fi

  # Verify submodule is at the expected commit
  current_commit=$(git -C "$ui_ref" rev-parse HEAD)
  if [ "$current_commit" != "$sha" ]; then
    echo "✗ $ui_ref is at $current_commit but $parent pins $sha" >&2
    errors=1
  else
    echo "✓ $ui_ref matches $parent argo-ui pin ($sha)"
  fi
}

# Orchestrate verification of all *-ui-ref submodules.
verify_ui_refs() {
  echo ">>> Verifying *-ui-ref checkouts against parent UI package.json pins"
  verify_ui_ref sources/argo-cd-ui-ref sources/argo-cd
  verify_ui_ref sources/argo-rollouts-ui-ref sources/argo-rollouts
}

# Download the release tarball for an extension source and extract the JS file
# to the given destination path.
#   $1: source_path  - config.yaml source path (e.g. sources/rollout-extension)
#   $2: asset        - release asset filename (e.g. extension.tar)
#   $3: js_filename  - basename of the JS file to find in the extracted tar
#   $4: dest         - destination path for the JS file
sync_extension_js() {
  local source_path=$1 asset=$2 js_filename=$3 dest=$4

  echo ">>> Syncing extension JS: $dest"

  local url ref repo_url download_url
  url=$(config_source_field "$source_path" url)
  ref=$(config_source_field "$source_path" ref)

  if [ -z "$ref" ] || [ "$ref" = "null" ]; then
    echo "✗ No ref found for $source_path in $CONFIG"
    return 1
  fi

  repo_url=${url%.git}
  download_url="${repo_url}/releases/download/${ref}/${asset}"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" RETURN

  echo "- Downloading $download_url..."
  if ! curl -fsSLo "$tmp_dir/$asset" "$download_url"; then
    echo "✗ Failed to download $download_url"
    return 1
  fi

  echo "- Extracting $js_filename..."
  tar -xf "$tmp_dir/$asset" -C "$tmp_dir"

  local js_path
  js_path=$(find "$tmp_dir" -name "$js_filename" -type f | head -n1)
  if [ -z "$js_path" ]; then
    echo "✗ $js_filename not found in $asset"
    return 1
  fi

  # Copy to destination (ensure parent directory exists)
  mkdir -p "$(dirname "$dest")"
  cp "$js_path" "$dest"
  echo "✓ Updated $dest (ref: $ref)"
}

sync_extension_js_refs() {
  echo ">>> Syncing extension JS files from GitHub releases"
  sync_extension_js \
    sources/rollout-extension \
    extension.tar \
    extensions-Rollout.js \
    containers/argocd-extensions/extensions-Rollout.js

  sync_extension_js \
    sources/gitops-promoter \
    gitops-promoter-argocd-extension.tar.gz \
    extension-promoter.js \
    containers/argocd-promoter-extension/extension-promoter.js
}
