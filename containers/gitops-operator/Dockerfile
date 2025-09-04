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
# --

# TODO: switch to registry.redhat.io once the image is available
FROM registry.redhat.io/rhel8/go-toolset:1.24.6  AS builder
USER root

# Copy source code
COPY sources/gitops-operator /workspace

WORKDIR /workspace
ARG VERBOSE=2
ENV GOFLAGS="-mod=mod"
ENV CGO_ENABLED=1
ENV GOEXPERIMENT=strictfipsruntime
ENV GOOS=linux
RUN go mod download
RUN go build -tags strictfipsruntime -o bin/manager ./cmd/main.go
    
FROM registry.access.redhat.com/ubi8/ubi-minimal

ENV LANG=en_US.utf8

# Operator binary
COPY --from=builder /workspace/bin/manager /usr/local/bin/manager

# Redis HA script templates
COPY --from=builder /workspace/build/redis /var/lib/redis
USER 10001

ENTRYPOINT [ "/usr/local/bin/manager" ]
    
LABEL \
    name="openshift-gitops-1/gitops-rhel8-operator" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-operator-container" \
    com.redhat.delivery.appregistry="false" \
    upstream-vcs-type="git" \
    summary="Openshift GitOps Operator Dockerfile Template" \
    description="Red Hat OpenShift GitOps Operator" \
    maintainer="William Tam <wtam@redhat.com>"  \
    com.redhat.component="openshift-gitops-operator-container" \
    io.openshift.tags="openshift,gitops-operator" \
    io.k8s.display-name="Red Hat OpenShift GitOps Operator" \
    io.k8s.description="Red Hat OpenShift GitOps Operator" \
    io.openshift.maintainer.product="Red Hat OpenShift GitOps" \
    io.openshift.maintainer.component="William Tam <wtam@redhat.com>"
