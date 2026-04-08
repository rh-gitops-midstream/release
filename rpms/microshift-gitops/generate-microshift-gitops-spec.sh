#!/usr/bin/env bash

set -euxo pipefail
CONFIG=../../config.yaml

GITOPS_VERSION='1.20.0'
GITOPS_BUILD_SPEC_RELEASE='4' # %(echo ${CI_SPEC_RELEASE} | sed -e s/rhel-9-//g) in CPaaS

ARGO_CD_IMAGE_URL='registry.redhat.io/openshift-gitops-1/argocd-rhel9@sha256:ddf6e5c439c6bfca31a7f25c22cffc5102092184a33b9754c97697f81c78e97a'
ARGO_CD_IMAGE_TAG='v1.20.0-4'
REDIS_IMAGE_URL='registry.redhat.io/rhel9/redis-7@sha256:68940c73abf64acd33585ece12f046ea8e53127553b90431ce3ffc7860e51336'
REDIS_IMAGE_TAG='9.7-1774456925'

KONFLUX_ARGOCD_IMAGE_NAME=argocd
ARGO_CD_IMAGE_SHA_X86=sha256:5ab7948b9db1a38a6b3a2b659a5bc3a545d3e39038fe28a1162b3ca634f05475
ARGO_CD_IMAGE_SHA_ARM=sha256:9a967ddc1bb2c15b27e404a5b51573723742198f308df278c53a13df3b0255ae
REDIS_IMAGE_SHA_X86=sha256:3190fc99df7c2b0adbef63d0c8b441279061a874e4bf62977ae693c0ba921bd4
REDIS_IMAGE_SHA_ARM=sha256:a54079736ffef0a47de24ba9bff88bf41051bba868dc65a4c71b662ac10dc4fa

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
# GITOPS_VERSION=$($YQ_BIN e '.release.version' "$CONFIG")
# BUILD=$(cat ../../BUILD)
# GITOPS_VERSION=$($YQ_BIN e '.release.version' "$CONFIG")
# GITOPS_BUILD_SPEC_RELEASE=$(echo ${BUILD} | sed 's/^v//; s/-/./g')

ARGO_CD_IMAGE_BASE_REF=$(KONFLUX_ARGOCD_IMAGE_NAME_VAR="$KONFLUX_ARGOCD_IMAGE_NAME" $YQ_BIN e '(.konfluxImages[] | select(.name == env(KONFLUX_ARGOCD_IMAGE_NAME_VAR))).releaseRef' "$CONFIG")
REDIS_IMAGE_BASE_REF=$($YQ_BIN e '(.externalImages[] | select(.name == "redis")).image' "$CONFIG")
CI_ARGO_CD_UPSTREAM_COMMIT=$($YQ_BIN e '(.sources[] | select(.path == "sources/argo-cd")).commit' "$CONFIG")
CI_ARGO_CD_UPSTREAM_URL_RAW=$($YQ_BIN e '(.sources[] | select(.path == "sources/argo-cd")).url' "$CONFIG")
CI_ARGO_CD_UPSTREAM_URL=$(printf '%s' "${CI_ARGO_CD_UPSTREAM_URL_RAW}" | sed 's/\.git$//')

cat microshift-gitops.spec.in > microshift-gitops.spec

sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_X86|${ARGO_CD_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_CONTAINER_SHA_ARM|${ARGO_CD_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_IMAGE_URL|${ARGO_CD_IMAGE_BASE_REF}|g" microshift-gitops.spec
sed -i "s|REPLACE_ARGO_CD_VERSION|${ARGO_CD_IMAGE_TAG}|g" microshift-gitops.spec

sed -i "s|REPLACE_REDIS_CONTAINER_SHA_X86|${REDIS_IMAGE_SHA_X86}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_CONTAINER_SHA_ARM|${REDIS_IMAGE_SHA_ARM}|g" microshift-gitops.spec
sed -i "s|REPLACE_REDIS_IMAGE_URL|${REDIS_IMAGE_BASE_REF}|g" microshift-gitops.spec

sed -i "s|REPLACE_CI_GITOPS_VERSION|${GITOPS_VERSION}|g" microshift-gitops.spec
sed -i "s|REPLACE_CI_SPEC_RELEASE|${GITOPS_BUILD_SPEC_RELEASE}|g" microshift-gitops.spec
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