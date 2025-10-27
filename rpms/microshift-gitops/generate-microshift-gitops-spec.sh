#!/usr/bin/env bash


# TODO: refactor the script 

set -euxo pipefail
CONFIG=../../config.yaml


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

CI_ARGO_CD_UPSTREAM_COMMIT=$($YQ_BIN e '(.sources[] | select(.path == "sources/argo-cd")).commit' "$CONFIG")
GITOPS_VERSION=$($YQ_BIN e '.release.version' "$CONFIG")
GITOPS_RELEASE=$($YQ_BIN e '.release.version' "$CONFIG")
REDIS_IMAGE_REF=$($YQ_BIN e '(.externalImages[] | select(.name == "redis")).image' "$CONFIG")


CI_ARGO_CD_UPSTREAM_URL=https://github.com/argoproj/argo-cd

cat microshift-gitops.spec.in > microshift-gitops.spec

sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_X86|${ARGO_CD_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_ARM|${ARGO_CD_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_IMAGE_URL|${ARGO_CD_IMAGE_REF}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_VERSION|${GITOPS_VERSION}|g" microshift-gitops.spec

sed -i "s|REPLACE_REDIS_CONTAINER_SHA_X86|${REDIS_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_CONTAINER_SHA_ARM|${REDIS_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_IMAGE_URL|${REDIS_IMAGE_REF}|g" microshift-gitops.spec

sed -i "s|REPLACE_MICROSHIFT_GITOPS_RELEASE|${GITOPS_RELEASE}|g" microshift-gitops.spec
sed -i "s|REPLACE_MICROSHIFT_GITOPS_VERSION|${GITOPS_VERSION}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_URL|${CI_ARGO_CD_UPSTREAM_URL}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_ARGO_CD_UPSTREAM_COMMIT|${CI_ARGO_CD_UPSTREAM_COMMIT}|g" microshift-gitops.spec

echo "generate-microshift-gitops-spec finished successfully."