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
# Builder stage which performs the build of Argocd-cli binaries
####################################################################################################
FROM registry.redhat.io/rhel8/go-toolset:1.25.3 AS builder

USER root

COPY sources/argo-cd /go/src/github.com/argoproj/argo-cd
WORKDIR /go/src/github.com/argoproj/argo-cd

ARG CI_ARGO_CD_VERSION
ARG CI_ARGO_CD_COMMIT
ARG CI_VERSION

ENV PACKAGE="github.com/argoproj/argo-cd/v3/common" \
    GIT_TREE_STATE="clean"

ENV GOFLAGS="-mod=mod" 

ENV EXTRA_BUILD_INFO="{Vendor Information: Red Hat OpenShift GitOps version: $CI_VERSION}"

RUN go mod download
RUN make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-linux-amd64 GOOS=linux GOARCH=amd64 argocd-all    && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-linux-arm64 GOOS=linux GOARCH=arm64 argocd-all    && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-linux-ppc64le GOOS=linux GOARCH=ppc64le argocd-all    && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-linux-s390x GOOS=linux GOARCH=s390x argocd-all    && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-windows-amd64.exe GOOS=windows GOARCH=amd64 argocd-all   && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-darwin-amd64 GOOS=darwin GOARCH=amd64 argocd-all          && \
    make GIT_TAG="v$(cat VERSION)" BIN_NAME=argocd-darwin-arm64 GOOS=darwin GOARCH=arm64 argocd-all  

# Make binaries executable and package them
RUN cd dist && \
    chmod +x argocd-linux-amd64 && tar -czvf argocd-linux-amd64.tar.gz argocd-linux-amd64 && \
    chmod +x argocd-linux-arm64 && tar -czvf argocd-linux-arm64.tar.gz argocd-linux-arm64 && \
    chmod +x argocd-linux-ppc64le && tar -czvf argocd-linux-ppc64le.tar.gz argocd-linux-ppc64le && \
    chmod +x argocd-linux-s390x && tar -czvf argocd-linux-s390x.tar.gz argocd-linux-s390x && \
    chmod +x argocd-darwin-amd64 && tar -czvf argocd-darwin-amd64.tar.gz argocd-darwin-amd64 && \
    chmod +x argocd-darwin-arm64  && tar -czvf argocd-darwin-arm64.tar.gz argocd-darwin-arm64 && \
    tar -czvf argocd-windows-amd64.tar.gz argocd-windows-amd64.exe     

####################################################################################################
# Package the binaries into the image using UBI (Universal Base Image)
####################################################################################################
FROM registry.access.redhat.com/ubi8/ubi

# This directory is checked by the ecosystem-cert-preflight-checks task in Konflux
COPY LICENSE /licenses/

# Set the user to the default non-root user provided by UBI
USER 999

WORKDIR /releases

# Copy the built plugin binaries into the final image
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-linux-amd64.tar.gz /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-linux-arm64.tar.gz /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-linux-ppc64le.tar.gz /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-linux-s390x.tar.gz /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-windows-amd64.tar.gz /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-darwin-amd64.tar.gz  /releases
COPY --from=builder /go/src/github.com/argoproj/argo-cd/dist/argocd-darwin-arm64.tar.gz  /releases


# Add required labels
LABEL name="Argo CD CLI binaries" \
    summary="Argo CD CLI binaries" \
    description="Argo CD CLI binaries for various platforms, including Darwin and Linux." \
    com.redhat.component="openshift-gitops-argocd-cli-container" \
    io.k8s.description="Red Hat Openshift GitOps Argo CD CLI"