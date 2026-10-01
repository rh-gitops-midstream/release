ARG BASE_IMAGE=quay.io/devtools_gitops/test_image:testsuites
FROM ${BASE_IMAGE}

LABEL name="gitops-release-bundle-test-runner" \
      description="GitOps release bundle-install sanity test runner with helper scripts" \
      maintainer="GitOps Team" \
      io.openshift.tags="gitops,testing,bundle,operator-sdk"

# Node.js + Playwright for UI E2E tests
ARG NODE_VERSION=v20.18.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) NODE_ARCH="x64";; aarch64) NODE_ARCH="arm64";; esac && \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1 && \
    node --version && npm --version

# operator-sdk CLI, needed to install the GitOps operator directly from its
# bundle image (`operator-sdk run bundle`) instead of via a full FBC catalog.
ARG OPERATOR_SDK_VERSION=v1.39.1
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) SDK_ARCH="amd64";; aarch64) SDK_ARCH="arm64";; esac && \
    curl -fsSL -o /usr/local/bin/operator-sdk \
      "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_linux_${SDK_ARCH}" && \
    chmod +x /usr/local/bin/operator-sdk && \
    operator-sdk version

# Copy helper scripts
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py /usr/local/bin/lib/*.sh

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
