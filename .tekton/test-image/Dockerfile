ARG BASE_IMAGE=quay.io/devtools_gitops/test_image:testsuites
FROM ${BASE_IMAGE}

LABEL name="gitops-ginkgo-test-runner" \
      description="GitOps integration test runner with helper scripts" \
      maintainer="GitOps Team" \
      io.openshift.tags="gitops,testing,ginkgo,integration"

# Node.js + Playwright for UI E2E tests
ARG NODE_VERSION=v20.18.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) NODE_ARCH="x64";; aarch64) NODE_ARCH="arm64";; esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1 && \
    node --version && npm --version

# Pre-compile argo-cd E2E test binary + CLI for arm64 (EaaS HyperShift clusters).
# Compilation requires ~6Gi RAM which exceeds the test step's limits, so we do it
# here where the build system has more resources. The test step uses the pre-built
# artifacts when branch and target arch match, otherwise recompiles using the warm
# Go module and build caches baked into the image.
ARG ARGOCD_E2E_REPO=https://github.com/argoproj/argo-cd.git
ARG ARGOCD_E2E_BRANCH=master
RUN mkdir -p /prebuilt/argocd-e2e /usr/local/go-cache/build /usr/local/go-cache/mod && \
    git clone --depth 1 -b "${ARGOCD_E2E_BRANCH}" "${ARGOCD_E2E_REPO}" /tmp/argo-cd && \
    cd /tmp/argo-cd && \
    export GOCACHE=/usr/local/go-cache/build GOMODCACHE=/usr/local/go-cache/mod && \
    export GOARCH=arm64 GOOS=linux CGO_ENABLED=0 GOTOOLCHAIN=auto && \
    go mod download && \
    CLIENT_VERSION=$(cat VERSION 2>/dev/null || echo "${ARGOCD_E2E_BRANCH}") && \
    CLIENT_VERSION="${CLIENT_VERSION#v}" && \
    echo "Compiling e2e.test for arm64..." && \
    go test -c \
      -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
      -o /prebuilt/argocd-e2e/e2e.test ./test/e2e && \
    echo "Compiling argocd CLI for arm64..." && \
    go build \
      -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
      -o /prebuilt/argocd-e2e/argocd ./cmd && \
    tar czf /prebuilt/argocd-e2e/test-fixtures.tar.gz test/ && \
    echo "${ARGOCD_E2E_BRANCH}" > /prebuilt/argocd-e2e/BRANCH && \
    echo "arm64" > /prebuilt/argocd-e2e/GOARCH && \
    rm -rf /tmp/argo-cd

# Copy helper scripts and config files
COPY scripts/ /usr/local/bin/
COPY skip-*.txt /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
