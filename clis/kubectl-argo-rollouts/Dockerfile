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

####################################################################################################
# Argo Rollouts UI stage
####################################################################################################
FROM registry.access.redhat.com/ubi8/nodejs-20 AS argo-rollouts-ui

USER root

# Install Yarn
WORKDIR /usr/src/app
COPY ["prefetch/yarn/package.json", "prefetch/yarn/package-lock.json", "./"]
RUN npm install --prefer-offline --no-progress --non-interactive
ENV YARN="/usr/src/app/node_modules/.bin/yarn"
RUN $YARN --version

WORKDIR /usr/src/app/argo-rollouts/ui

COPY ["sources/argo-rollouts/ui/package.json", "sources/argo-rollouts/ui/yarn.lock", "./"]

RUN $YARN  install --no-progress --non-interactive --prefer-offline --network-timeout 300000 && \
    $YARN cache clean

COPY ["sources/argo-rollouts/ui/", "."]

ARG ARGO_VERSION=latest
ENV ARGO_VERSION=$ARGO_VERSION
RUN NODE_ONLINE_ENV='offline' NODE_ENV='production' $YARN build


####################################################################################################
# Builder stage which performs the build of argo-rollouts-cli binaries
####################################################################################################

FROM registry.redhat.io/rhel8/go-toolset:1.25 AS builder

# Switch to root user
USER root

# Set Go environment variables
ENV GOFLAGS="-mod=mod"

# Set the working directory for the build
COPY sources/argo-rollouts /src/argo-rollouts
WORKDIR /src/argo-rollouts

# Download Go dependencies
RUN go mod download

# Copy UI files for plugin build
COPY --from=argo-rollouts-ui /usr/src/app/argo-rollouts/ui/dist/app /src/argo-rollouts/ui/dist/app

# Create required UI build markers to avoid rebuilds without Yarn installed
RUN mkdir -p ui/dist/app && \
    touch ui/dist/node_modules.marker && \
    touch ui/dist/app/index.html && \
    find ui/dist

# These build args are computed by Konflux custom task(.tekton/tasks/generate-metadata.yaml) and passed to docker build
ARG CI_ARGO_ROLLOUTS_VERSION
ARG CI_ARGO_ROLLOUTS_COMMIT

# Build the plugins for multiple platforms
RUN make plugin-linux plugin-darwin plugin-windows \
    VERSION="${CI_ARGO_ROLLOUTS_VERSION}" \
    GIT_COMMIT="${CI_ARGO_ROLLOUTS_COMMIT}" \
    GIT_TAG="${CI_ARGO_ROLLOUTS_VERSION}" \
    GIT_TREE_STATE="clean"

# Package binaries into tar.gz archives (required by Konflux)
RUN cd dist && \
    chmod +x kubectl-argo-rollouts-linux-amd64 && tar -czvf kubectl-argo-rollouts-linux-amd64.tar.gz kubectl-argo-rollouts-linux-amd64 && \
    chmod +x kubectl-argo-rollouts-linux-arm64 && tar -czvf kubectl-argo-rollouts-linux-arm64.tar.gz kubectl-argo-rollouts-linux-arm64 && \
    chmod +x kubectl-argo-rollouts-darwin-amd64 && tar -czvf kubectl-argo-rollouts-darwin-amd64.tar.gz kubectl-argo-rollouts-darwin-amd64 && \
    chmod +x kubectl-argo-rollouts-darwin-arm64 && tar -czvf kubectl-argo-rollouts-darwin-arm64.tar.gz kubectl-argo-rollouts-darwin-arm64 && \
    chmod +x kubectl-argo-rollouts-windows-amd64 && tar -czvf kubectl-argo-rollouts-windows-amd64.tar.gz kubectl-argo-rollouts-windows-amd64

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
COPY --from=builder /src/argo-rollouts/dist/kubectl-argo-rollouts-linux-amd64.tar.gz /releases/
COPY --from=builder /src/argo-rollouts/dist/kubectl-argo-rollouts-linux-arm64.tar.gz /releases/
COPY --from=builder /src/argo-rollouts/dist/kubectl-argo-rollouts-darwin-amd64.tar.gz /releases/
COPY --from=builder /src/argo-rollouts/dist/kubectl-argo-rollouts-darwin-arm64.tar.gz /releases/
COPY --from=builder /src/argo-rollouts/dist/kubectl-argo-rollouts-windows-amd64.tar.gz /releases/

# Add required labels
LABEL name="Argo Rollouts Kubectl plugin binaries" \
      summary="Argo Rollouts Kubectl plugin binaries" \
      description="Argo Rollouts Kubectl plugin binaries for various platforms, including Darwin and Linux." \
      component="openshift-gitops-argo-rollouts-cli-container" \
      io.k8s.description="Red Hat Openshift GitOps Argo Rollouts CLI"

