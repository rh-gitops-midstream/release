#!/usr/bin/env bash

set -euxo pipefail

# Prerequisites:
# - jq
# - sed
# - skopeo
# installed in the image

# This script retrieves the latest container images for ArgoCD and Redis,
# inspects them to find the correct image digests for different architectures,
# and then updates the RPM spec file with these values.

CI_ARGO_CD_UPSTREAM_COMMIT="-"
GITOPS_TAG_PREFIX="v${GITOPS_VERSION}"
CI_ARGO_CD_UPSTREAM_URL=https://github.com/argoproj/argo-cd

# --- ARGOCD build steps ---

# Construct the full image URL for ArgoCD.
ARGO_CD_IMAGE_URL="${GITOPS_REGISTRY}/${GITOPS_IMAGE_NAME}"
# Find the latest tag for the ArgoCD image using skopeo.
# List all tags, filter them using the prefix, exclude source tags, sort them, and get the last one that match v${GITOPS_VERSION}.
ARGO_CD_IMAGE_TAG=$(skopeo list-tags "docker://${ARGO_CD_IMAGE_URL}" | jq -r ".Tags[]" | grep "^${GITOPS_TAG_PREFIX}" | grep -v -- "-source$" | sort -V | tail -n 1)

echo "Latest Argo CD Image Tag: ${ARGO_CD_IMAGE_TAG}"

# Construct the full image reference with the tag.
ARGO_CD_FULL_IMAGE_REF="docker://${ARGO_CD_IMAGE_URL}:${ARGO_CD_IMAGE_TAG}"

# Get the SHA digests for x86_64 (amd64) and aarch64 (arm64) architectures.
# skopeo inspect gives us a manifest list, and we use jq to parse it.
ARGO_CD_IMAGE_SHA_X86=$(skopeo inspect --raw "${ARGO_CD_FULL_IMAGE_REF}" | jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest')
ARGO_CD_IMAGE_SHA_ARM=$(skopeo inspect --raw "${ARGO_CD_FULL_IMAGE_REF}" | jq -r '.manifests[] | select(.platform.architecture=="arm64") | .digest')

cat microshift-gitops.spec.in > microshift-gitops.spec

echo "Argo CD SHA (x86_64): ${ARGO_CD_IMAGE_SHA_X86}"
echo "Argo CD SHA (aarch64): ${ARGO_CD_IMAGE_SHA_ARM}"

# Update the placeholder variables in the spec template file.
sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_X86|${ARGO_CD_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_ARM|${ARGO_CD_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_VERSION|${ARGO_CD_IMAGE_TAG}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_IMAGE_URL|${ARGO_CD_IMAGE_URL}|g" microshift-gitops.spec

# --- REDIS build steps ---

# Construct the full image URL for Redis.
REDIS_IMAGE_URL="${REDIS_REGISTRY}/${REDIS_IMAGE_NAME}"

# Find the latest tag for the Redis image.
# List all tags, filter them using the prefix, exclude source tags, sort them, and get the last one.
REDIS_IMAGE_TAG=$(skopeo list-tags "docker://${REDIS_IMAGE_URL}" | jq -r ".Tags[]" | grep "^${REDIS_TAG_PREFIX}" | grep -v -- "-source$" | sort -V | tail -n 1)
echo "Latest Redis Image Tag: ${REDIS_IMAGE_TAG}"

# Construct the full image reference with the tag.
REDIS_FULL_IMAGE_REF="docker://${REDIS_IMAGE_URL}:${REDIS_IMAGE_TAG}"

# Get the SHA digests for x86_64 (amd64) and aarch64 (arm64) architectures.
REDIS_IMAGE_SHA_X86=$(skopeo inspect --raw "${REDIS_FULL_IMAGE_REF}" | jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest')
REDIS_IMAGE_SHA_ARM=$(skopeo inspect --raw "${REDIS_FULL_IMAGE_REF}" | jq -r '.manifests[] | select(.platform.architecture=="arm64") | .digest')

echo "Redis SHA (x86_64): ${REDIS_IMAGE_SHA_X86}"
echo "Redis SHA (aarch64): ${REDIS_IMAGE_SHA_ARM}"

# Update the placeholder variables in the spec template file.
sed -i "s|REPLACE_REDIS_CONTAINER_SHA_X86|${REDIS_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_CONTAINER_SHA_ARM|${REDIS_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_IMAGE_URL|${REDIS_IMAGE_URL}|g" microshift-gitops.spec


sed -i "s|REPLACE_MICROSHIFT_GITOPS_RELEASE|${GITOPS_RELEASE}|g" microshift-gitops.spec
sed -i "s|REPLACE_MICROSHIFT_GITOPS_VERSION|${GITOPS_VERSION}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_URL|${CI_ARGO_CD_UPSTREAM_URL}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_COMMIT|${CI_ARGO_CD_UPSTREAM_COMMIT}|g" microshift-gitops.spec

echo "generate-spec-file finished successfully."