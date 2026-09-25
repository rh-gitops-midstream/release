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
