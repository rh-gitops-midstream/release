# Copyright 2023 Red Hat
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
# Argo Rollouts Openshift Routes Plugin Build stage which performs the actual build of Argo Rollouts binaries
####################################################################################################

FROM brew.registry.redhat.io/rh-osbs/openshift-golang-builder:rhel_8_1.24 as rollouts-plugin-trafficrouter-openshift-build
USER root

COPY sources/rollouts-plugin-trafficrouter-openshift/ /go/src/github.com/argoproj/rollouts-plugin-trafficrouter-openshift
WORKDIR /go/src/github.com/argoproj/rollouts-plugin-trafficrouter-openshift/

ENV GOFLAGS="-mod=mod"
ENV CGO_ENABLED=1
ENV GOEXPERIMENT=strictfipsruntime

# Perform the build
RUN CGO_ENABLED=1 GOEXPERIMENT=strictfipsruntime go build -v -tags strictfipsruntime  -o ./dist/rollouts-plugin-trafficrouter-openshift .

####################################################################################################
# Argo Rollouts Build stage which performs the actual build of Argo Rollouts binaries
####################################################################################################

FROM brew.registry.redhat.io/rh-osbs/openshift-golang-builder:rhel_8_1.24 AS argo-rollouts-build
USER root

COPY sources/argo-rollouts/ /go/src/github.com/argoproj/argo-rollouts
WORKDIR /go/src/github.com/argoproj/argo-rollouts/

ARG CI_ARGO_ROLLOUTS_VERSION
ARG CI_ARGO_ROLLOUTS_COMMIT
ENV GOFLAGS="-mod=mod"
ENV CGO_ENABLED=1
ENV GOEXPERIMENT=strictfipsruntime

# Perform the build
RUN CGO_ENABLED=1 GOEXPERIMENT=strictfipsruntime \
go build -v -ldflags "-X github.com/argoproj/argo-rollouts/utils/version.version=${CI_ARGO_ROLLOUTS_VERSION} \
  -X github.com/argoproj/argo-rollouts/utils/version.buildDate=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
  -X github.com/argoproj/argo-rollouts/utils/version.gitCommit=${CI_ARGO_ROLLOUTS_COMMIT} \
  -X github.com/argoproj/argo-rollouts/utils/version.gitTreeState=clean \
  -X github.com/argoproj/argo-rollouts.gitTag=${CI_ARGO_ROLLOUTS_VERSION}" \
  -tags strictfipsruntime -o ./dist/rollouts-controller ./cmd/rollouts-controller

# build git-lfs
COPY sources/git-lfs/ /go/src/github.com/argoproj/git-lfs
WORKDIR /go/src/github.com/argoproj/git-lfs/
RUN ls -lha
ARG CI_GIT_LFS_COMMIT
RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 \
 go build -ldflags="-w -s -X 'github.com/git-lfs/git-lfs/v3/config.Vendor=Red Hat Inc' \
 -X github.com/git-lfs/git-lfs/v3/config.GitCommit=${CI_GIT_LFS_COMMIT}" \
 -gcflags="" -tags strictfipsruntime -trimpath  -o ./bin/git-lfs ./git-lfs.go

####################################################################################################
# Final image
####################################################################################################
####################################################################################################
# Argo Rollouts Base - used as the base for both the release and dev argo rollouts images
####################################################################################################
FROM registry.access.redhat.com/ubi8/ubi-minimal AS argo-rollouts-base

USER root
RUN microdnf install shadow-utils  -y

RUN groupadd -g 999 argo-rollouts && \
    useradd -l -r -u 999 -g argo-rollouts argo-rollouts && \
    mkdir -p /home/argo-rollouts && \
    chown argo-rollouts:0 /home/argo-rollouts && \
    chmod g=u /home/argo-rollouts && \
    microdnf install -y git gpg tar tzdata && \
    microdnf clean all && \
    rm -rf /tmp/* /var/tmp/*

# support for mounting configuration from a configmap
RUN mkdir -p /app/config/ssh && \
    touch /app/config/ssh/ssh_known_hosts && \
    ln -s /app/config/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts 

RUN mkdir -p /app/config/tls
RUN mkdir -p /app/config/gpg/source && \
    mkdir -p /app/config/gpg/keys && \
    chown argo-rollouts /app/config/gpg/keys && \
    chmod 0700 /app/config/gpg/keys
# Create directory for storing the binary for the default route plugin
RUN mkdir -p /plugins/rollouts-trafficrouter-openshift/

USER 999

WORKDIR /home/argo-rollouts

# Create the binary for the default route plugin to the plugins directory
COPY --from=rollouts-plugin-trafficrouter-openshift-build /go/src/github.com/argoproj/rollouts-plugin-trafficrouter-openshift/dist/rollouts-plugin-trafficrouter-openshift /plugins/rollouts-trafficrouter-openshift/openshift-route-plugin

COPY --from=argo-rollouts-build /go/src/github.com/argoproj/argo-rollouts/dist/rollouts-controller /usr/local/bin/
COPY --from=argo-rollouts-build /go/src/github.com/argoproj/git-lfs/bin/git-lfs /usr/local/bin/

LABEL \
    name="openshift-gitops-1/argo-rollouts-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argo-rollouts-container" \
    cpe="cpe:/a:redhat:openshift_gitops:1.17::el8" \
    com.redhat.delivery.appregistry="false" \
    upstream-vcs-type="git" \
    summary="Red Hat Openshift GitOps Argo Rollouts" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,argorollouts" \
    io.k8s.display-name="openshift-gitops-argo-rollouts" \
    io.k8s.description="Red Hat Openshift GitOps Argo Rollouts" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat Openshift GitOps Argo Rollouts"

ENTRYPOINT [ "/usr/local/bin/rollouts-controller"]
