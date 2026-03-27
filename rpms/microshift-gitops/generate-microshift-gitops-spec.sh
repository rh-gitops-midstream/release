#!/usr/bin/env bash

set -euxo pipefail
CONFIG=../../config.yaml

#GITOPS_VERSION=${{ inputs.gitops_version }}
#GITOPS_RELEASE=${{ inputs.gitops_release }}
KONFLUX_ARGOCD_IMAGE_NAME=argocd
ARGO_CD_IMAGE_SHA_X86=sha256:ea4f3f8e721945a2ca03156e50b1b76aabf2ebef72fb9db57eebf526b730f5a4
ARGO_CD_IMAGE_SHA_ARM=sha256:aeccbbcdb0f4311c3c2f1408f6e72fbfb73273138f3fddd7f3b678e71ee7f3e7
REDIS_IMAGE_SHA_X86=sha256:ad8e2ce8ead4bc11e8697b0d60ed6db83c6d60e93e087072716ff15ba70508aa
REDIS_IMAGE_SHA_ARM=sha256:f068347b33ed0c005dbd33759765e79f22d0d33f04fb3e14504fd2dfb22dd14a

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