#!/bin/bash
#
# Script to update the argocd-agent helm chart with RedHat-specific configurations.
#
# IMPORTANT: This script should be run from a tagged branch or from the main branch.
# The script accepts the image tag as input parameter.
#
# Usage:
#   ./helm-chart/publish.sh <tag>
#
# Arguments:
#   tag - The image tag (e.g., v1.18.1-2) to use for the argocd-agent image
#
# Prerequisites:
#   - git submodule initialized
#   - yq installed (available in bin/yq)
#   - helm-docs installed and available in PATH
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/sources/argocd-agent/install/helm-repo/argocd-agent-agent"
CONFIG_YAML="${REPO_ROOT}/config.yaml"
YQ="${REPO_ROOT}/bin/yq"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse command-line arguments
if [ $# -eq 0 ]; then
    error "Tag argument is required"
    echo "Usage: $0 <tag>"
    echo "Example: $0 v1.18.1-2"
    exit 1
fi

TAG="$1"

# Validate tag format (should be like v1.18.1-2)
if [[ ! "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
    error "Invalid tag format. Expected format: v<major>.<minor>.<patch>[-<build>]"
    error "Example: v1.18.1-2"
    error "Received: ${TAG}"
    exit 1
fi

info "Using image tag: ${TAG}"

# Check if yq is available
if [ ! -f "${YQ}" ]; then
    error "yq not found at ${YQ}"
    exit 1
fi

# Check if helm-docs is available
if ! command -v helm-docs &> /dev/null; then
    error "helm-docs is not installed. Please install helm-docs."
    error "Installation: go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest"
    exit 1
fi

# Check if config.yaml exists
if [ ! -f "${CONFIG_YAML}" ]; then
    error "config.yaml not found: ${CONFIG_YAML}"
    exit 1
fi

# Extract commit and ref from config.yaml for sources/argocd-agent
info "Reading commit and ref from config.yaml for sources/argocd-agent..."
ARGOCD_AGENT_COMMIT=$("${YQ}" eval '.sources[] | select(.path == "sources/argocd-agent") | .commit' "${CONFIG_YAML}")
ARGOCD_AGENT_REF=$("${YQ}" eval '.sources[] | select(.path == "sources/argocd-agent") | .ref' "${CONFIG_YAML}")

if [ -z "${ARGOCD_AGENT_COMMIT}" ] || [ "${ARGOCD_AGENT_COMMIT}" == "null" ]; then
    error "Failed to extract commit from config.yaml for sources/argocd-agent"
    exit 1
fi

if [ -z "${ARGOCD_AGENT_REF}" ] || [ "${ARGOCD_AGENT_REF}" == "null" ]; then
    error "Failed to extract ref from config.yaml for sources/argocd-agent"
    exit 1
fi

info "Found commit: ${ARGOCD_AGENT_COMMIT}"
info "Found ref: ${ARGOCD_AGENT_REF}"

# Get the current branch name
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
info "Current branch: ${BRANCH_NAME}"

# Check if we're on main branch or a tagged branch
if [ "${BRANCH_NAME}" != "main" ] && ! git describe --tags --exact-match HEAD &> /dev/null; then
    warn "You are not on 'main' branch or a tagged commit. Proceeding anyway..."
fi

# Initialize and update the argocd-agent submodule
info "Initializing and updating argocd-agent submodule..."
cd "${REPO_ROOT}"
git submodule update --init --recursive sources/argocd-agent || {
    error "Failed to initialize argocd-agent submodule"
    exit 1
}

# Check if chart directory exists
if [ ! -d "${CHART_DIR}" ]; then
    error "Chart directory not found: ${CHART_DIR}"
    exit 1
fi

CHART_YAML="${CHART_DIR}/Chart.yaml"
VALUES_YAML="${CHART_DIR}/values.yaml"

# Check if required files exist
if [ ! -f "${CHART_YAML}" ]; then
    error "Chart.yaml not found: ${CHART_YAML}"
    exit 1
fi

if [ ! -f "${VALUES_YAML}" ]; then
    error "values.yaml not found: ${VALUES_YAML}"
    exit 1
fi

# Copy helm chart to directory under helm-chart with commit-ref naming
HELM_CHART_OUTPUT_DIR="${SCRIPT_DIR}/${ARGOCD_AGENT_COMMIT}-${ARGOCD_AGENT_REF}"
info "Copying helm chart to directory: ${HELM_CHART_OUTPUT_DIR}"

# Create output directory
mkdir -p "${HELM_CHART_OUTPUT_DIR}"

# Copy the entire chart directory contents (including hidden files)
# Using cp -a to preserve all attributes and copy recursively
cp -a "${CHART_DIR}/." "${HELM_CHART_OUTPUT_DIR}/" || {
    error "Failed to copy helm chart to output directory"
    exit 1
}

info "Helm chart copied successfully to: ${HELM_CHART_OUTPUT_DIR}"

# Now work with the copy instead of the original sources/ directory
TEMP_CHART_YAML="${HELM_CHART_OUTPUT_DIR}/Chart.yaml"
TEMP_VALUES_YAML="${HELM_CHART_OUTPUT_DIR}/values.yaml"

# Update Chart.yaml in the copy
info "Updating Chart.yaml in the copy..."
"${YQ}" eval '.description = "RedHat Argo CD Agent for connecting managed clusters to a Principal"' -i "${TEMP_CHART_YAML}"
"${YQ}" eval '.annotations."charts.openshift.io/name" = "RedHat Argo CD Agent - Agent Component"' -i "${TEMP_CHART_YAML}"

info "Chart.yaml updated successfully"

# Update values.yaml in the copy - set image repository
info "Updating values.yaml in the copy with new image repository..."
IMAGE_REPO="registry.redhat.io/openshift-gitops-1/argocd-agent-rhel8"
IMAGE_FULL="${IMAGE_REPO}:${TAG}"
info "Setting image repository to: ${IMAGE_REPO}"
"${YQ}" eval '.image.repository = "registry.redhat.io/openshift-gitops-1/argocd-agent-rhel8"' -i "${TEMP_VALUES_YAML}"

# Update values.yaml in the copy - set image tag
info "Setting image tag to: ${TAG}"
"${YQ}" eval ".image.tag = \"${TAG}\"" -i "${TEMP_VALUES_YAML}"

info "values.yaml updated successfully"
info "Full image reference: ${IMAGE_FULL}"

# Generate helm chart documentation using helm-docs on the copy
info "Generating helm chart documentation..."
cd "${HELM_CHART_OUTPUT_DIR}"
helm-docs --chart-search-root . --output-file README.md || {
    error "Failed to generate helm chart documentation"
    exit 1
}
cd "${REPO_ROOT}"
info "Helm chart documentation generated successfully"

info "Helm chart update completed successfully!"
info "Chart name: redhat-argocd-agent"
info "Image repository: ${IMAGE_REPO}"
info "Image tag: ${TAG}"
info "Full image: ${IMAGE_FULL}"
info "Output chart directory: ${HELM_CHART_OUTPUT_DIR}"

