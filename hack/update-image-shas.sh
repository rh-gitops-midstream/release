#!/usr/bin/env bash

set -euo pipefail

BRANCH_NAME="${BRANCH_NAME:-main}"
MAPPING_FILE="image-mapping.yaml"
CSV_FILE="gitops-operator-bundle/patches/csv.yaml"
CSV_ENV_FILE="gitops-operator-bundle/patches/csv-env.yaml"

if ! command -v skopeo &> /dev/null; then
  echo "❌ skopeo not installed. Please install it to proceed."
  exit 1
fi

echo "🔁 Processing image updates from $MAPPING_FILE..."

yq e '.images[]' "$MAPPING_FILE" -o=json | jq -c '.' | while read -r image; do
  SOURCE=$(echo "$image" | jq -r '.source')
  TARGET=$(echo "$image" | jq -r '.target')
  PATH_FIELD=$(echo "$image" | jq -r '.path // empty')

  if [[ -z "$PATH_FIELD" ]]; then
    echo "❌ Missing 'path' for image $SOURCE"
    exit 1
  fi

  if compgen -G "${PATH_FIELD}/*Dockerfile" >/dev/null; then
    echo "🔨 Internal image: ${SOURCE} (found Dockerfile in ${PATH_FIELD})"
    SOURCE_TAGGED="${SOURCE}:${BRANCH_NAME}"
    DIGEST=$(skopeo inspect --override-os linux --override-arch amd64  docker://"$SOURCE_TAGGED" | jq -r '.Digest')

    if [[ -z "$DIGEST" || "$DIGEST" == "null" ]]; then
      echo "❌ Failed to get digest for ${SOURCE_TAGGED}"
      exit 1
    fi

    FULL_IMAGE="${TARGET}@${DIGEST}"
  elif [[ -f "${PATH_FIELD}/image.yaml" ]]; then
    echo "📦 External image: using value from ${PATH_FIELD}/image.yaml"
    FULL_IMAGE=$(cat "${PATH_FIELD}/image.yaml")

    if [[ -z "$FULL_IMAGE" || "$FULL_IMAGE" == "null" ]]; then
      echo "❌ Missing or invalid image value in ${PATH_FIELD}/image.yaml"
      exit 1
    fi
  else
    echo "❌ Neither Dockerfile nor image.yaml found in ${PATH_FIELD}"
    exit 1
  fi

  echo "✏️ Replacing ${TARGET}@sha256:<digest> with ${FULL_IMAGE} in ${CSV_FILE}"
  sed -i '' "s|${TARGET}@sha256:[a-f0-9]\{64\}|${FULL_IMAGE}|g" "$CSV_FILE"
  echo "✏️ Replacing ${TARGET}@sha256:<digest> with ${FULL_IMAGE} in ${CSV_ENV_FILE}"
  sed -i '' "s|${TARGET}@sha256:[a-f0-9]\{64\}|${FULL_IMAGE}|g" "$CSV_ENV_FILE"

done

echo "✅ Image references updated in CSV patches."
