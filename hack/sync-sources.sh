#!/usr/bin/env bash
set -euo pipefail

source ./hack/deps.sh

CONFIG=config.yaml

echo ">>> Initializing submodules..."
git submodule update --init --recursive

echo ">>> Syncing sources from $CONFIG..."
count=$($YQ e '.sources | length' "$CONFIG")

for i in $(seq 0 $((count - 1))); do
  path=$($YQ e ".sources[$i].path" "$CONFIG")
  url=$($YQ e ".sources[$i].url" "$CONFIG")
  commit=$($YQ e ".sources[$i].commit" "$CONFIG")

  # Check if submodule exists
  if ! git config -f .gitmodules --get-regexp path | awk '{print $2}' | grep -qx "$path"; then
    echo ">>> Submodule $path not found. Adding..."
    git submodule add "$url" "$path"
  fi

  echo ">>> Syncing $path"

  (
    cd "$path"
    git fetch origin
    git checkout "$commit"
  )
done

echo ">>> Sync completed."
