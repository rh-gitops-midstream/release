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
FROM registry.access.redhat.com/ubi9/nodejs-20 AS argocd-ui

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
# Argo CD Build stage which performs the actual build of Argo CD binaries
####################################################################################################
# TODO: switch to registry.redhat.io once the image is available
FROM registry.redhat.io/rhel9/go-toolset:1.24.6 as argocd-build
USER root

COPY sources/argo-cd /go/src/github.com/argoproj/argo-cd
WORKDIR /go/src/github.com/argoproj/argo-cd

ENV GOFLAGS="-mod=mod"

# build with strictfips
ENV GOEXPERIMENT=strictfipsruntime
ENV CGO_ENABLED=1
ENV CGO_FLAG=1

ARG CI_VERSION
ARG CI_ARGO_CD_COMMIT
ARG CI_ARGO_CD_VERSION
ENV EXTRA_BUILD_INFO="{Vendor Information: Red Hat OpenShift GitOps version: $CI_VERSION}"

# Perform the build
COPY --from=argocd-ui /usr/src/app/argo-cd/ui/dist/app /go/src/github.com/argoproj/argo-cd/ui/dist/app
RUN export PACKAGE=github.com/argoproj/argo-cd/v3/common &&\
export VERSION=$(cat VERSION) &&\
export BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') &&\
export KUBECTL_VER=$(go list -m k8s.io/client-go | head -n 1 | rev | cut -d' ' -f1 | rev) &&\
export GOEXPERIMENT=strictfipsruntime &&\
export CGO_ENABLED=1 &&\
export GODEBUG="tarinsecurepath=0,zipinsecurepath=0" &&\
export LDFLAGS="-X ${PACKAGE}.version=${VERSION} \
  -X ${PACKAGE}.buildDate=${BUILD_DATE} \
  -X ${PACKAGE}.gitCommit=${CI_ARGO_CD_COMMIT} \
  -X ${PACKAGE}.gitTreeState=clean \
  -X ${PACKAGE}.kubectlVersion=${KUBECTL_VER}\
  -X \"${PACKAGE}.extraBuildInfo=${EXTRA_BUILD_INFO}\"" &&\
go build -gcflags="all=-N -l" -v -ldflags "${LDFLAGS}" -tags strictfipsruntime -o ./dist/argocd ./cmd

# Create static linked binary to be called from different base images.
RUN export PACKAGE=github.com/argoproj/argo-cd/v2/common &&\
    export VERSION=$(cat VERSION) &&\
    export BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') &&\
    export KUBECTL_VER=$(go list -m k8s.io/client-go | head -n 1 | rev | cut -d' ' -f1 | rev) &&\
    export GOEXPERIMENT='' &&\
    export CGO_ENABLED=0 &&\
    export GODEBUG="tarinsecurepath=0,zipinsecurepath=0" &&\
    export LDFLAGS="-extldflags \"-static\" -X ${PACKAGE}.version=${VERSION} \
        -X ${PACKAGE}.buildDate=${BUILD_DATE} \
        -X ${PACKAGE}.gitCommit=${CI_ARGO_CD_COMMIT} \
        -X ${PACKAGE}.gitTreeState=clean \
        -X ${PACKAGE}.kubectlVersion=${KUBECTL_VER}\
        -X \"${PACKAGE}.extraBuildInfo=${EXTRA_BUILD_INFO}\"" &&\
    go build -gcflags="all=-N -l" -v -ldflags "${LDFLAGS}" -o ./dist/argocd-cmp-server ./cmd

ARG BUILD_ALL_CLIS=false
RUN if [ "$BUILD_ALL_CLIS" = "true" ] ; then \
    make CLI_NAME=argocd-darwin-amd64 GOOS=darwin GOARCH=amd64 cli-local && \
    make CLI_NAME=argocd-windows-amd64.exe GOOS=windows GOARCH=amd64 cli-local \
    ; fi

# build kustomize
COPY sources/kustomize /go/src/github.com/argoproj/kustomize
WORKDIR /go/src/github.com/argoproj/kustomize/kustomize
ARG CI_KUSTOMIZE_VERSION
ENV GOSUMDB=off
RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 go build -mod=readonly -buildvcs=true -ldflags="-s -X sigs.k8s.io/kustomize/api/provenance.version=${CI_KUSTOMIZE_VERSION#kustomize/} \
-X sigs.k8s.io/kustomize/api/provenance.buildDate=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
-tags strictfipsruntime -o kustomize .

# build helm
COPY sources/helm /go/src/github.com/argoproj/helm
WORKDIR /go/src/github.com/argoproj/helm
ARG CI_HELM_VERSION
ARG CI_HELM_COMMIT
RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 go build -ldflags="-w -s -X helm.sh/helm/v3/internal/version.version=${CI_HELM_VERSION} \
-X helm.sh/helm/v3/internal/version.gitCommit=${CI_HELM_COMMIT}" -tags strictfipsruntime ./cmd/helm

# build tini
COPY sources/tini /go/src/github.com/argoproj/tini
WORKDIR /go/src/github.com/argoproj/tini
ENV CFLAGS="-DPR_SET_CHILD_SUBREAPER=36 -DPR_GET_CHILD_SUBREAPER=37"
RUN yum install -y cmake
RUN cmake . && make tini

# build connect-proxy
COPY sources/ssh-connect /go/src/github.com/argoproj/ssh-connect
WORKDIR /go/src/github.com/argoproj/ssh-connect
RUN sed -i 's/SOCKLEN_T/socklen_t/g' connect.c 
RUN gcc -v connect.c -o connect-proxy

# build git-lfs
COPY sources/git-lfs /go/src/github.com/argoproj/git-lfs
WORKDIR /go/src/github.com/argoproj/git-lfs
ARG CI_GIT_LFS_COMMIT
RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 \
 go build -ldflags="-w -s -X 'github.com/git-lfs/git-lfs/v3/config.Vendor=Red Hat Inc' \
 -X github.com/git-lfs/git-lfs/v3/config.GitCommit=${CI_GIT_LFS_COMMIT}" \
 -gcflags="" -tags strictfipsruntime -trimpath  -o ./bin/git-lfs ./git-lfs.go

####################################################################################################
# Final image
####################################################################################################
####################################################################################################
# Argo CD Base - used as the base for both the release and dev argocd images
####################################################################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal AS argocd-base

USER root
RUN microdnf install shadow-utils -y

RUN groupadd -g 999 argocd && \
    useradd -l -r -u 999 -g argocd -d /home/argocd argocd && \
    mkdir -p /home/argocd && \
    chown argocd:0 /home/argocd && \
    chmod g=u /home/argocd && \
    microdnf install -y git gpg tar tzdata && \
    microdnf clean all && \
    rm -rf /tmp/* /var/tmp/*

COPY sources/argo-cd/hack/gpg-wrapper.sh /usr/local/bin/gpg-wrapper.sh
COPY sources/argo-cd/hack/git-verify-wrapper.sh /usr/local/bin/git-verify-wrapper.sh

COPY sources/argo-cd/entrypoint.sh /usr/local/bin/entrypoint.sh
# keep uid_entrypoint.sh for backward compatibility
RUN ln -s /usr/local/bin/entrypoint.sh /usr/local/bin/uid_entrypoint.sh

# support for mounting configuration from a configmap
RUN mkdir -p /app/config/ssh && \
    touch /app/config/ssh/ssh_known_hosts && \
    ln -s /app/config/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts 

RUN mkdir -p /app/config/tls
RUN mkdir -p /app/config/gpg/source && \
    mkdir -p /app/config/gpg/keys && \
    chown argocd /app/config/gpg/keys && \
    chmod 0700 /app/config/gpg/keys

# workaround ksonnet issue https://github.com/ksonnet/ksonnet/issues/298
ENV USER=argocd

WORKDIR /home/argocd

COPY --from=argocd-build /go/src/github.com/argoproj/argo-cd/dist/argocd /usr/local/bin/
COPY --from=argocd-build /go/src/github.com/argoproj/argo-cd/dist/argocd-cmp-server /usr/local/bin/
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-server
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-repo-server
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-application-controller
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-dex
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-notifications
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-applicationset-controller
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-k8s-auth

USER 999
COPY --from=argocd-build  /go/src/github.com/argoproj/kustomize/kustomize/kustomize /usr/local/bin/
COPY --from=argocd-build  /go/src/github.com/argoproj/helm/helm /usr/local/bin/
COPY --from=argocd-build  /go/src/github.com/argoproj/tini/tini /usr/local/bin/
COPY --from=argocd-build  /go/src/github.com/argoproj/ssh-connect/connect-proxy /usr/local/bin/connect-proxy
COPY --from=argocd-build  /go/src/github.com/argoproj/git-lfs/bin/git-lfs /usr/local/bin/

LABEL \
    name="openshift-gitops-1/argocd-rhel9" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argocd-container" \
    com.redhat.delivery.appregistry="false" \
    upstream-vcs-type="git" \
    summary="Red Hat Openshift GitOps Argo CD" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,argocd" \
    io.k8s.display-name="openshift-gitops-argocd" \
    io.k8s.description="Red Hat Openshift GitOps Argo CD" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat Openshift GitOps Argo CD"
