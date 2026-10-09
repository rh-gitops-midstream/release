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
FROM registry.redhat.io/rhel9/go-toolset:1.26 AS builder
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

####################################################################################################
# Build tini from source. tini is the image entrypoint and reaps the git child processes that the
# image updater forks; without it they accumulate as zombies (GITOPS-11648). There is no tini RPM
# in the UBI9 repos, so it is built from the pinned sources/tini submodule, the same way the argocd
# and gitops-promoter images do it.
####################################################################################################
FROM registry.redhat.io/rhel9/go-toolset:1.26 AS tini-build
USER root

# Install cmake and build tini from the source in midstream
WORKDIR /src/tini
# TODO: install gcc to switch to a UBI9 base image instead of go-toolset, which is a heavier image but contains gcc.
RUN yum install -y cmake
COPY sources/tini /src/tini
ENV CFLAGS="-DPR_SET_CHILD_SUBREAPER=36 -DPR_GET_CHILD_SUBREAPER=37"
RUN cmake . && make tini

# Final image
FROM registry.access.redhat.com/ubi9/ubi-minimal

USER root
RUN microdnf install -y shadow-utils ca-certificates git-core openssh-clients gpg tar && \
    microdnf clean all && \
    rm -rf /tmp/* /var/tmp/*

RUN useradd -l -r -u 1000 -d /app argocd && \
    mkdir -p /app/config && \
    chown -R argocd:0 /app && \
    chmod -R g=u /app

COPY --from=builder /src/argocd-image-updater/dist/argocd-image-updater /manager
COPY --from=tini-build /src/tini/tini /usr/local/bin/tini
COPY sources/argocd-image-updater/hack/git-ask-pass.sh /usr/local/bin/git-ask-pass.sh

WORKDIR /app
USER 1000
# Run the manager under tini so that tini is PID 1 and reaps exited git child processes.
# Upstream uses /sbin/tini (from the alpine package); here tini is built from source, so it
# lives in /usr/local/bin alongside the other locally built binaries, as in the argocd image.
ENTRYPOINT ["/usr/local/bin/tini", "--", "/manager"]

LABEL \
    name="openshift-gitops-1/argocd-image-updater-rhel9" \
    cpe="cpe:/a:redhat:openshift_gitops:99.99::el9" \
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
