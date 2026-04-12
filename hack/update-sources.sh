#!/usr/bin/env bash
set -euo pipefail

source ./hack/deps.sh

CONFIG=${1:-config.yaml}
IGNORED_BRANCH_REFS=(main master)
errors=0
updated=0

is_ignored_branch_ref() {
  local ref=$1

  for ignored_ref in "${IGNORED_BRANCH_REFS[@]}"; do
    if [ "$ref" = "$ignored_ref" ]; then
      return 0
    fi
  done

  return 1
}

escape_regex() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g; s#/#\\/#g'
}

tag_commit() {
  local url=$1
  local ref=$2
  local peeled_commit

  peeled_commit=$(git ls-remote "$url" "refs/tags/$ref^{}" | awk 'NR == 1 { print $1 }')
  if [ -n "$peeled_commit" ]; then
    printf '%s\n' "$peeled_commit"
    return 0
  fi

  git ls-remote --tags --refs "$url" "refs/tags/$ref" | awk 'NR == 1 { print $1 }'
}

branch_commit() {
  local url=$1
  local ref=$2

  git ls-remote --heads "$url" "refs/heads/$ref" | awk 'NR == 1 { print $1 }'
}

find_latest_zstream_tag() {
  local url=$1
  local current_ref=$2
  local tags
  local tag_pattern
  local prefix
  local version
  local major
  local minor
  local latest_tag

  version=$(printf '%s\n' "$current_ref" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
  if [ -z "$version" ]; then
    return 1
  fi

  prefix=${current_ref%"$version"}
  IFS=. read -r major minor _ <<< "$version"

  if [ -z "$major" ] || [ -z "$minor" ]; then
    return 1
  fi

  tag_pattern="^$(escape_regex "$prefix")${major}\\.${minor}(\\.[0-9]+)?$"

  tags=$(git ls-remote --tags --refs "$url" | awk '{sub("refs/tags/", "", $2); print $2}')
  latest_tag=$(printf '%s\n' "$tags" | grep -E "$tag_pattern" | grep -Ev '(-|\+)' || true)
  latest_tag=$(printf '%s\n' "$latest_tag" | sort -V | tail -n 1)

  if [ -z "$latest_tag" ]; then
    return 1
  fi

  printf '%s\n' "$latest_tag"
}

classify_ref() {
  local url=$1
  local ref=$2

  if git ls-remote --exit-code --heads "$url" "refs/heads/$ref" >/dev/null 2>&1; then
    printf 'branch\n'
    return 0
  fi

  if git ls-remote --exit-code --tags --refs "$url" "refs/tags/$ref" >/dev/null 2>&1; then
    printf 'tag\n'
    return 0
  fi

  return 1
}

echo ">>> Updating sources in $CONFIG..."
count=$($YQ e '.sources | length' "$CONFIG")

if [ "$count" -eq 0 ]; then
  echo ">>> No sources entries found."
  exit 0
fi

for i in $(seq 0 $((count - 1))); do
  path=$($YQ e ".sources[$i].path" "$CONFIG")
  url=$($YQ e ".sources[$i].url" "$CONFIG")
  ref=$($YQ e ".sources[$i].ref" "$CONFIG")
  commit=$($YQ e ".sources[$i].commit" "$CONFIG")

  echo ">>> Processing $path ($ref)"

  if ! ref_type=$(classify_ref "$url" "$ref"); then
    echo "✗ Could not resolve ref '$ref' in $url"
    errors=1
    continue
  fi

  case "$ref_type" in
    branch)
      if is_ignored_branch_ref "$ref"; then
        echo "- Skipping ignored branch ref '$ref'"
        continue
      fi

      new_commit=$(branch_commit "$url" "$ref")
      if [ -z "$new_commit" ]; then
        echo "✗ Could not resolve latest commit for branch '$ref' in $url"
        errors=1
        continue
      fi

      if [ "$new_commit" = "$commit" ]; then
        echo "- Branch commit already up to date at $commit"
        continue
      fi

      $YQ e -i ".sources[$i].commit = \"$new_commit\"" "$CONFIG"
      echo "✓ Updated commit: $commit -> $new_commit"
      updated=$((updated + 1))
      ;;
    tag)
      if latest_ref=$(find_latest_zstream_tag "$url" "$ref"); then
        new_ref=$latest_ref
      else
        new_ref=$ref
      fi

      new_commit=$(tag_commit "$url" "$new_ref")
      if [ -z "$new_commit" ]; then
        echo "✗ Could not resolve commit for tag '$new_ref' in $url"
        errors=1
        continue
      fi

      if [ "$new_ref" = "$ref" ] && [ "$new_commit" = "$commit" ]; then
        echo "- Tag already up to date at $ref ($commit)"
        continue
      fi

      if [ "$new_ref" != "$ref" ]; then
        $YQ e -i ".sources[$i].ref = \"$new_ref\"" "$CONFIG"
        echo "✓ Updated ref: $ref -> $new_ref"
      fi

      if [ "$new_commit" != "$commit" ]; then
        $YQ e -i ".sources[$i].commit = \"$new_commit\"" "$CONFIG"
        echo "✓ Updated commit: $commit -> $new_commit"
      fi

      updated=$((updated + 1))
      ;;
  esac
done

if [ "$errors" -ne 0 ]; then
  echo ">>> Source update finished with errors."
  exit 1
fi

echo ">>> Updated $updated source entries."
