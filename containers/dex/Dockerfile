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

# --- start build stage #1
FROM registry.redhat.io/rhel8/go-toolset:1.23 as builder

COPY sources/dex /app/dex
WORKDIR /app/dex

ARG CI_DEX_VERSION
ARG CI_DEX_COMMIT
ENV GOFLAGS=""
RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 GOOS=linux go build -mod=mod -o /tmp/dex -ldflags "-w -X main.version=$CI_DEX_VERSION -X main.commit=$CI_DEX_COMMIT" -tags strictfipsruntime ./cmd/dex

# --- start build stage #2
FROM registry.access.redhat.com/ubi8/ubi-minimal
# Dex connectors, such as GitHub and Google logins require root certificates.
# Proper installations should manage those certificates, but it's a bad user
# experience when this doesn't work out of the box.
#
# OpenSSL is required so wget can query HTTPS endpoints for health checking.

RUN microdnf install -y ca-certificates openssl && microdnf clean all

RUN mkdir -p /var/dex
RUN chown -R 1001:1001 /var/dex

RUN mkdir -p /etc/dex
COPY --from=builder /app/dex/config.docker.yaml /etc/dex/
RUN chown -R 1001:1001 /etc/dex

COPY --from=builder /app/dex/api/v2/go.mod /app/dex/api/v2/go.sum /usr/local/src/api/v2/

COPY --from=builder /tmp/dex /usr/local/bin/dex
COPY --from=builder /app/dex/web /srv/dex/web

USER 1001:1001

LABEL \
    name="openshift-gitops-1/dex-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-dex-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Dex" \
    downstream-vcs-type="git" \
    upstream-vcs-type="git" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,dex,sso" \
    io.k8s.display-name="Red Hat OpenShift GitOps Dex" \
    io.k8s.description="Red Hat OpenShift GitOps Dex" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Dex"
