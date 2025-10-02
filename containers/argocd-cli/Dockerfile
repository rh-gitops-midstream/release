# Copyright 2021 Red Hat
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ------------------------------------------------------------------------

####################################################################################################
# Argo CD UI stage
####################################################################################################
FROM registry.access.redhat.com/ubi8/nodejs-20 AS argocd-ui

USER root

# Install Yarn
WORKDIR /usr/src/app
COPY ["prefetch/yarn/package.json", "prefetch/yarn/package-lock.json", "./"]
RUN npm install --prefer-offline --no-progress --non-interactive
ENV YARN="/usr/src/app/node_modules/.bin/yarn"
RUN $YARN --version

WORKDIR /usr/src/app/argo-cd/ui

COPY ["sources/argo-cd/ui/package.json", "sources/argo-cd/ui/yarn.lock", "./"]

RUN $YARN  install --no-progress --non-interactive --prefer-offline --network-timeout 200000 && \
    $YARN cache clean

COPY ["sources/argo-cd/ui/", "."]

ARG ARGO_VERSION=latest
ENV ARGO_VERSION=$ARGO_VERSION
RUN NODE_ONLINE_ENV='offline' NODE_ENV='production' $YARN build

####################################################################################################
# Argo CD Build stage which performs the actual build of Argocd-cli binaries
####################################################################################################
FROM registry.redhat.io/rhel8/go-toolset:1.24.6 AS release-cli-build

USER root

# --- ArgoCD Build Setup ---
COPY sources/argo-cd /go/src/github.com/argoproj/argo-cd
WORKDIR /go/src/github.com/argoproj/argo-cd

COPY --from=argocd-ui /usr/src/app/argo-cd/ui/dist/app ./ui/dist/app

ARG CI_ARGO_CD_VERSION
ARG CI_ARGO_CD_COMMIT
ARG CI_VERSION
ENV EXTRA_BUILD_INFO="{Vendor Information: Red Hat OpenShift GitOps version: $CI_VERSION}"

ENV PACKAGE="github.com/argoproj/argo-cd/v3/common" \
    GIT_TREE_STATE="clean"

RUN go mod download
RUN go clean -cache
RUN rm -rf dist && mkdir -p dist

RUN \
    set -eux; \
    export CGO_ENABLED=0; \
    export BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); \
    export KUBECTL_VER=$(go list -m k8s.io/client-go | head -n 1 | rev | cut -d' ' -f1 | rev); \
    BASE_LDFLAGS="-X ${PACKAGE}.version=${CI_ARGO_CD_VERSION} -X ${PACKAGE}.buildDate=${BUILD_DATE} -X ${PACKAGE}.gitCommit=${CI_ARGO_CD_COMMIT} -X ${PACKAGE}.gitTreeState=${GIT_TREE_STATE} -X ${PACKAGE}.kubectlVersion=${KUBECTL_VER} -X '${PACKAGE}.extraBuildInfo=${EXTRA_BUILD_INFO}'"; \
    for target in linux/amd64 linux/arm64 linux/ppc64le linux/s390x; do \
        GOOS=$(echo ${target} | cut -d'/' -f1); \
        GOARCH=$(echo ${target} | cut -d'/' -f2); \
        OUTPUT_NAME="argocd-${GOOS}-${GOARCH}"; \
        LDFLAGS="${BASE_LDFLAGS} -extldflags '-static'"; \
        echo "Building for ${target}..."; \
        go build -v -ldflags "$LDFLAGS" -o "dist/${OUTPUT_NAME}" ./cmd; \
    done

RUN \
    set -eux; \
    echo "Packaging binaries for Konflux release..."; \
    mkdir -p /releases; \
    mv dist/* /releases/; \
    cd /releases; \
    tar -czf argocd-linux-amd64.tar.gz argocd-linux-amd64; \
    tar -czf argocd-linux-arm64.tar.gz argocd-linux-arm64; \
    tar -czf argocd-linux-ppc64le.tar.gz argocd-linux-ppc64le; \
    tar -czf argocd-linux-s390x.tar.gz argocd-linux-s390x; \
    echo "Konflux packaging complete. Artifacts are in /releases."
