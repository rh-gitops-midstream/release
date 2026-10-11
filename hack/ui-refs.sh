#!/usr/bin/env bash
# Sourced by update-sources.sh, sync-sources.sh, and verify-sources.sh.
# *-ui-ref submodules follow the argo-ui git pin in the parent product UI.

PKG_FILE=ui/package.json

config_source_field() {
  local path=$1
  local field=$2

  $YQ e ".sources[] | select(.path == \"${path}\") | .${field}" "$CONFIG"
}

# Print the 40-char argo-ui SHA from package.json contents.
argo_ui_sha() {
  local pkg_json=$1
  local dep sha

  dep=$($YQ e '.dependencies["argo-ui"]' - <<< "$pkg_json")
  sha=${dep##*#}
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

# Use the local checkout when it already matches config.yaml; otherwise fetch
# from GitHub (update-sources.sh writes the new commit before checkout).
argo_ui_sha_at_commit() {
  local parent=$1
  local commit=$2
  local url=$3
  local pkg_json repo

  if [ -f "$parent/$PKG_FILE" ] && [ "$(git -C "$parent" rev-parse HEAD 2>/dev/null || true)" = "$commit" ]; then
    pkg_json=$(cat "$parent/$PKG_FILE")
  else
    repo=${url#https://github.com/}
    repo=${repo%.git}
    if ! pkg_json=$(curl -fsSL "https://raw.githubusercontent.com/${repo}/${commit}/${PKG_FILE}"); then
      return 1
    fi
  fi

  argo_ui_sha "$pkg_json"
}

checkout_ui_ref() {
  local ui_ref=$1
  local parent=$2
  local url commit sha current

  echo ">>> Processing $ui_ref (from $parent $PKG_FILE)"

  url=$(config_source_field "$parent" url)
  commit=$(config_source_field "$parent" commit)
  if [ -z "$url" ] || [ -z "$commit" ] || [ "$url" = "null" ] || [ "$commit" = "null" ]; then
    echo "✗ Parent source $parent not found in $CONFIG"
    return 1
  fi

  if ! sha=$(argo_ui_sha_at_commit "$parent" "$commit" "$url"); then
    echo "✗ Could not read argo-ui git pin from $parent@$commit $PKG_FILE"
    return 1
  fi

  if [ ! -e "$ui_ref/.git" ]; then
    echo ">>> Initializing submodule $ui_ref"
    git submodule update --init "$ui_ref"
  fi

  current=$(git -C "$ui_ref" rev-parse HEAD)
  if [ "$current" = "$sha" ]; then
    echo "- Already at $sha"
    return 0
  fi

  (
    cd "$ui_ref"
    git fetch origin
    git checkout "$sha"
  )
  echo "✓ Checked out $current -> $sha"
}

sync_ui_refs() {
  echo ">>> Syncing *-ui-ref checkouts from parent UI package.json"
  checkout_ui_ref sources/argo-cd-ui-ref sources/argo-cd
  checkout_ui_ref sources/argo-rollouts-ui-ref sources/argo-rollouts
}

verify_ui_ref() {
  local ui_ref=$1
  local parent=$2
  local sha current_commit

  echo ">>> Verifying $ui_ref"

  if [ ! -f "$parent/$PKG_FILE" ]; then
    echo "✗ $parent/$PKG_FILE not found"
    errors=1
    return
  fi

  if ! sha=$(argo_ui_sha "$(cat "$parent/$PKG_FILE")"); then
    echo "✗ Could not read argo-ui git pin from $parent/$PKG_FILE"
    errors=1
    return
  fi

  current_commit=$(git -C "$ui_ref" rev-parse HEAD)
  if [ "$current_commit" != "$sha" ]; then
    echo "✗ $ui_ref is at $current_commit but $parent pins $sha"
    errors=1
  else
    echo "✓ Matches $parent argo-ui pin $sha"
  fi
}

verify_ui_refs() {
  echo ">>> Verifying *-ui-ref checkouts against parent UI package.json"
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
  trap "rm -rf $tmp_dir" RETURN

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

  cp "$js_path" "$dest"
  echo "✓ Updated $dest to $ref"
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
