#!/usr/bin/env bash
set -euo pipefail

source ./hack/deps.sh
CONFIG=config.yaml
errors=0

echo ">>> Verifying sources from $CONFIG..."
count=$($YQ e '.sources | length' "$CONFIG")

for i in $(seq 0 $((count - 1))); do
  path=$($YQ e ".sources[$i].path" "$CONFIG")
  url=$($YQ e ".sources[$i].url" "$CONFIG")
  commit=$($YQ e ".sources[$i].commit" "$CONFIG")
  ref=$($YQ e ".sources[$i].ref" "$CONFIG")

  echo ">>> Verifying $path"

  # Verify commit
  current_commit=$(git -C "$path" rev-parse HEAD)
  if [ "$current_commit" != "$commit" ]; then
    echo "✗ $path is at $current_commit but expected $commit"
    errors=1
  else
    echo "✓ Commit matches"
  fi

  # Check if ref exists (tag first, then branch)
  if git ls-remote --exit-code --tags "$url" "refs/tags/$ref" >/dev/null 2>&1; then
    echo "✓ $ref exists as a tag"
  elif git ls-remote --exit-code --heads "$url" "$ref" >/dev/null 2>&1; then
    echo "✓ $ref exists as a branch"
  else
    echo "✗ $ref does not exist in $url"
    errors=1
  fi

done

if [ "$errors" -ne 0 ]; then
  echo ">>> One or more sources failed verification."
  exit 1
else
  echo ">>> All sources verified successfully."
fi