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
# Argo CD Agentctl Build stage which performs the actual build of Argocd-agentctl binaries
####################################################################################################
FROM registry.redhat.io/rhel9/go-toolset:9.7 AS builder

USER root

COPY sources/argocd-agent /src/argocd-agentctl
WORKDIR /src/argocd-agentctl

ENV GOFLAGS="-mod=mod" 

RUN go mod download
RUN make cli-all

# Make binaries executable and package them
RUN cd dist && \
    chmod +x argocd-agentctl_linux-amd64 && tar -czvf argocd-agentctl-linux-amd64.tar.gz argocd-agentctl_linux-amd64 && \
    chmod +x argocd-agentctl_linux-arm64 && tar -czvf argocd-agentctl-linux-arm64.tar.gz argocd-agentctl_linux-arm64 && \
    chmod +x argocd-agentctl_darwin-amd64 && tar -czvf argocd-agentctl-darwin-amd64.tar.gz argocd-agentctl_darwin-amd64 && \
    chmod +x argocd-agentctl_darwin-arm64 && tar -czvf argocd-agentctl-darwin-arm64.tar.gz argocd-agentctl_darwin-arm64 && \
    chmod +x argocd-agentctl_linux-arm && tar -czvf argocd-agentctl-linux-arm.tar.gz argocd-agentctl_linux-arm

####################################################################################################
# Package the binaries into the image using UBI (Universal Base Image)
####################################################################################################
FROM registry.access.redhat.com/ubi9/ubi

# This directory is checked by the ecosystem-cert-preflight-checks task in Konflux
COPY LICENSE /licenses/

# Set the user to the default non-root user provided by UBI
USER 999

WORKDIR /releases

# Copy the built plugin binaries into the final image
COPY --from=builder /src/argocd-agentctl/dist/argocd-agentctl-linux-amd64.tar.gz /releases
COPY --from=builder /src/argocd-agentctl/dist/argocd-agentctl-linux-arm64.tar.gz /releases
COPY --from=builder /src/argocd-agentctl/dist/argocd-agentctl-darwin-amd64.tar.gz /releases
COPY --from=builder /src/argocd-agentctl/dist/argocd-agentctl-darwin-arm64.tar.gz /releases
COPY --from=builder /src/argocd-agentctl/dist/argocd-agentctl-linux-arm.tar.gz /releases

# Add required labels
LABEL name="Argo agentctl binaries" \
    summary="Argo agentctl binaries" \
    description="Argo agentctl binaries for various platforms, including Darwin and Linux." \
    component="openshift-gitops-argocd-agentctl-container" \
    io.k8s.description="Red Hat Openshift GitOps Argo CD AgentCTL"