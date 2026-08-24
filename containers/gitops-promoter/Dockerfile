# Copyright 2026 Red Hat
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
#
#

##################################################################################################
# GitOps Promoter Dashboard UI Build Stage
##################################################################################################
FROM registry.access.redhat.com/ubi9/nodejs-22 AS promoter-dashboard-ui

USER root

WORKDIR /app/gitops-promoter

# Copy all package files for better layer caching
COPY sources/gitops-promoter/ui/components-lib/package*.json ./ui/components-lib/
COPY sources/gitops-promoter/ui/dashboard/package*.json ./ui/dashboard

# Copy all UI sources
COPY sources/gitops-promoter/ui ./ui/

# Install deps for the component library
WORKDIR /app/gitops-promoter/ui/components-lib
RUN npm ci

# Install deps for the dashboard
WORKDIR /app/gitops-promoter/ui/dashboard
RUN npm ci

# Build the dashboard
RUN npx vite build
RUN mkdir -p ../web/static && cp -r dist/* ../web/static

#################################################################################################
# GitOps Promoter Binary Build Stage
#################################################################################################
FROM registry.access.redhat.com/rhel9/go-toolset:1.26 AS promoter-build

ARG TARGETOS
ARG TARGETARCH

USER root

WORKDIR /app/gitops-promoter

# Copy go modules and install deps
COPY sources/gitops-promoter/go.mod go.mod
COPY sources/gitops-promoter/go.sum go.sum
RUN go mod download

# Copy Go sources files for the Promoter
COPY sources/gitops-promoter/cmd/ cmd/
COPY sources/gitops-promoter/api/ api/
COPY sources/gitops-promoter/applyconfiguration/ applyconfiguration/
COPY sources/gitops-promoter/internal/ internal/
COPY sources/gitops-promoter/hack/git/promoter_askpass.sh hack/git/promoter_askpass.sh
COPY sources/gitops-promoter/ui/web/ ./ui/web

# Copy built UI static files for embedding into binary
COPY --from=promoter-dashboard-ui /app/gitops-promoter/ui/web/static ./ui/web/static

# Build binary
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -a -o gitops-promoter cmd/main.go

#################################################################################################
# Build tini binary
#################################################################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal AS tini-build

# Install cmake and build tini from the source in midstream
WORKDIR /src/tini
RUN microdnf install -y cmake gcc && microdnf clean all
COPY sources/tini /src/tini
ENV CFLAGS="-DPR_SET_CHILD_SUBREAPER=36 -DPR_GET_CHILD_SUBREAPER=37"
RUN cmake . && make tini

##################################################################################################
# Final Image Build
#################################################################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal AS promoter-base

WORKDIR /

# Install dependencies
RUN microdnf install -y git-core && microdnf clean all

# Copy over artifacts from other build phases
RUN mkdir /git
COPY --from=promoter-build /app/gitops-promoter/gitops-promoter .
COPY --from=promoter-build /app/gitops-promoter/hack/git/promoter_askpass.sh /git/promoter_askpass.sh
COPY --from=tini-build /src/tini/tini /usr/bin/
ENV PATH="${PATH}:/git"
RUN echo "${PATH}" >> /etc/bash.bashrc

USER 999

ENTRYPOINT ["/usr/bin/tini", "--", "/gitops-promoter"]

LABEL \
    name="openshift-gitops-1/gitops-promoter-rhel9" \
    cpe="cpe:/a:redhat:openshift_gitops:99.99::el9" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-gitops-promoter-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Gitops Promoter" \
    upstream-vcs-type="git" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,argocd,gitops-promoter" \
    io.k8s.display-name="openshift-gitops-gitops-promoter" \
    io.k8s.description="Red Hat OpenShift GitOps GitOps Promoter" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps GitOps Promoter"
