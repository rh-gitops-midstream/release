# Copyright 2025 Red Hat
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

# Build the manager binary
FROM registry.redhat.io/rhel9/go-toolset:1.25 AS builder
USER root

ARG CI_ARGOCD_IMAGE_UPDATER_VERSION
ARG CI_ARGOCD_IMAGE_UPDATER_COMMIT

COPY sources/argocd-image-updater /src/argocd-image-updater
WORKDIR /src/argocd-image-updater

RUN CGO_ENABLED=1 GOEXPERIMENT=strictfipsruntime \
    go build -tags strictfipsruntime \
    -ldflags "-X github.com/argoproj-labs/argocd-image-updater/pkg/version.version=${CI_ARGOCD_IMAGE_UPDATER_VERSION} \
              -X github.com/argoproj-labs/argocd-image-updater/pkg/version.gitCommit=${CI_ARGOCD_IMAGE_UPDATER_COMMIT} \
              -X github.com/argoproj-labs/argocd-image-updater/pkg/version.buildDate=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    -o dist/argocd-image-updater ./cmd

# Final image
FROM registry.access.redhat.com/ubi9/ubi-minimal

USER root
RUN microdnf install -y shadow-utils ca-certificates git openssh-clients gpg tar && \
    microdnf clean all && \
    rm -rf /tmp/* /var/tmp/*

RUN useradd -l -r -u 1000 -d /app argocd && \
    mkdir -p /app/config && \
    chown -R argocd:0 /app && \
    chmod -R g=u /app

COPY --from=builder /src/argocd-image-updater/dist/argocd-image-updater /manager
COPY sources/argocd-image-updater/hack/git-ask-pass.sh /usr/local/bin/git-ask-pass.sh

WORKDIR /app
USER 1000
ENTRYPOINT ["/manager"]

LABEL \
    name="openshift-gitops-1/argocd-image-updater-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argocd-image-updater-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Argo CD Image Updater" \
    upstream-vcs-type="git" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,argocd-image-updater" \
    io.k8s.display-name="openshift-gitops-argocd-image-updater" \
    io.k8s.description="Red Hat OpenShift GitOps Argo CD Image Updater" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Argo CD Image Updater"
