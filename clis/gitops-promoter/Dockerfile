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
# ------------------------------------------------------------------------

###################################################################################################
# GitOps Promoter Build stag which builds the GitOps Promoter binary that contains the dashboard
###################################################################################################
FROM registry.redhat.io/rhel9/go-toolset:1.26 AS builder

USER root

COPY sources/gitops-promoter /src/gitops-promoter
WORKDIR /src/gitops-promoter

ENV GOFLAGS="-mod=mod"

# Currently there is no upstream Makefile target that builds the binary for different architectures and OSes
# So manually build all of them
# The gitops-promoter binary is shared between the apiserver, controller, and dashboard
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o gitops-promoter-linux-amd64 cmd/main.go && \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -o gitops-promoter-linux-arm64 cmd/main.go && \
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -a -o gitops-promoter-darwin-amd64 cmd/main.go && \
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -a -o gitops-promoter-darwin-arm64 cmd/main.go

RUN chmod +x gitops-promoter-linux-amd64 && tar -czvf gitops-promoter-linux-amd64.tar.gz gitops-promoter-linux-amd64 && \
    chmod +x gitops-promoter-linux-arm64 && tar -czvf gitops-promoter-linux-arm64.tar.gz gitops-promoter-linux-arm64 && \
    chmod +x gitops-promoter-darwin-amd64 && tar -czvf gitops-promoter-darwin-amd64.tar.gz gitops-promoter-darwin-amd64 && \
    chmod +x gitops-promoter-darwin-arm64 && tar -czvf gitops-promoter-darwin-arm64.tar.gz gitops-promoter-darwin-arm64

###################################################################################################
# Package binaries into the image using UBI
###################################################################################################
FROM registry.access.redhat.com/ubi9/ubi

# This directory is checked by the ecosystem-cert-preflight-checks task in Konflux
COPY LICENSE /licenses/

# Set the user to the default non-root user provided by UBI
USER 999

WORKDIR /releases

# Copy the built binaries into the final image
COPY --from=builder /src/gitops-promoter/gitops-promoter-linux-amd64.tar.gz /releases
COPY --from=builder /src/gitops-promoter/gitops-promoter-linux-arm64.tar.gz /releases
COPY --from=builder /src/gitops-promoter/gitops-promoter-darwin-amd64.tar.gz /releases
COPY --from=builder /src/gitops-promoter/gitops-promoter-darwin-arm64.tar.gz /releases

# Add required labels
LABEL name="GitOps Promoter Binaries" \
    summary="GitOps Promoter Binaries" \
    description="GitOps Promoter binaries for various platforms, including Darwin and Linux." \
    component="openshift-gitops-gitops-promoter-cli-container" \
    io.k8s.description="Red Hat Openshift GitOps GitOps Promoter CLI"
