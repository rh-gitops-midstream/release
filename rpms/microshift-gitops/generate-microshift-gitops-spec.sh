#!/usr/bin/env bash

set -euxo pipefail
CONFIG=../../config.yaml

#GITOPS_VERSION=${{ inputs.gitops_version }}
#GITOPS_RELEASE=${{ inputs.gitops_release }}
KONFLUX_ARGOCD_IMAGE_NAME=argocd
ARGO_CD_IMAGE_SHA_X86=sha256:6fb646fbd35b779be50ceca8d12a8736ed43ebe4f40204ca28851db2e2cfdf20
ARGO_CD_IMAGE_SHA_ARM=sha256:7ce92cc4c69bd9cd64e5dfedad15388be5d9404ac916731b86f5cf490993756b
REDIS_IMAGE_SHA_X86=sha256:1be9e6e067a7595a5a51da709d262c1f4a5eca2fe2033450a9737a5354170c00
REDIS_IMAGE_SHA_ARM=sha256:9a21acdd1cb1d3faf577c6d9d24045e5da86e2f6b1c1a4438dfcc80e21f112d6

BIN_DIR="./bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH" # Add our local bin to the PATH

YQ_VERSION="v4.22.1"
YQ_BIN="$BIN_DIR/yq"

# Check if yq is installed in our local bin; if not, download it.
if [ ! -f "$YQ_BIN" ]; then
  echo ">>> Installing yq ${YQ_VERSION}..."
  # Detect OS and Architecture to download the correct binary.
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  case $ARCH in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
  esac

  curl -sSfLo "$YQ_BIN" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
  chmod +x "$YQ_BIN"
fi

ARGO_CD_IMAGE_REF=$(KONFLUX_ARGOCD_IMAGE_NAME_VAR="$KONFLUX_ARGOCD_IMAGE_NAME" $YQ_BIN e '(.konfluxImages[] | select(.name == env(KONFLUX_ARGOCD_IMAGE_NAME_VAR))).releaseRef' "$CONFIG")

echo "Successfully found registry: ${ARGO_CD_IMAGE_REF}"
BUILD=$(cat ../../BUILD)

CI_ARGO_CD_UPSTREAM_COMMIT=$($YQ_BIN e '(.sources[] | select(.path == "sources/argo-cd")).commit' "$CONFIG")
CI_ARGO_CD_UPSTREAM_URL_RAW=$($YQ_BIN e '(.sources[] | select(.path == "sources/argo-cd")).url' "$CONFIG")
CI_ARGO_CD_UPSTREAM_URL=$(printf '%s' "${CI_ARGO_CD_UPSTREAM_URL_RAW}" | sed 's/\.git$//')
GITOPS_VERSION=$($YQ_BIN e '.release.version' "$CONFIG")
GITOPS_RELEASE=$(echo ${BUILD} | sed 's/^v//; s/-/./g')
REDIS_IMAGE_REF=$($YQ_BIN e '(.externalImages[] | select(.name == "redis")).image' "$CONFIG")

cat microshift-gitops.spec.in > microshift-gitops.spec

sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_X86|${ARGO_CD_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_ARM|${ARGO_CD_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_IMAGE_URL|${ARGO_CD_IMAGE_REF}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_VERSION|${BUILD}|g" microshift-gitops.spec

sed -i "s|REPLACE_REDIS_CONTAINER_SHA_X86|${REDIS_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_CONTAINER_SHA_ARM|${REDIS_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_IMAGE_URL|${REDIS_IMAGE_REF}|g" microshift-gitops.spec

sed -i "s|REPLACE_CI_GITOPS_VERSION|${GITOPS_VERSION}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_SPEC_RELEASE|${GITOPS_RELEASE}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_URL|${CI_ARGO_CD_UPSTREAM_URL}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_COMMIT|${CI_ARGO_CD_UPSTREAM_COMMIT}|g" microshift-gitops.spec

echo "generate-microshift-gitops-spec finished successfully."

echo "Generating argo-cd sources tarball and sources file."
TARBALL_DIR="$(pwd)"
TARBALL_NAME="argo-cd-sources.tar.gz"
SOURCE_DIR="../../sources"
TARBALL_PATH="${TARBALL_DIR}/${TARBALL_NAME}"

tar -czvf "${TARBALL_PATH}" --transform="s,^argo-cd,argo-cd," -C "${SOURCE_DIR}" argo-cd
sha512sum "${TARBALL_PATH}" | sed 's/^\([0-9a-f]\+\)  \(.*\)$/SHA512 (\2) = \1/' > "${TARBALL_DIR}/sources"