#!/bin/bash
# Shared utilities for oras operations and authentication setup.
# Source this file to use these functions in other scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/oras-helpers.sh"
#   setup_oras_auth
#   oras_push_tarball /path/to/logs quay.io/repo my-tag

# Configure Docker credentials for oras.
# Copies the .dockerconfigjson to a temporary directory and exports DOCKER_CONFIG.
#
# Args:
#   $1 - Path to .dockerconfigjson (default: /quay-credentials/.dockerconfigjson)
#
# Returns:
#   0 if credentials were set up successfully
#   1 if credentials file not found
#
# Sets:
#   DOCKER_CONFIG environment variable
setup_oras_auth() {
    local auth_path="${1:-/quay-credentials/.dockerconfigjson}"

    # Skip if already configured
    if [ -n "${DOCKER_CONFIG:-}" ] && [ -f "${DOCKER_CONFIG}/config.json" ]; then
        return 0
    fi

    if [ -f "$auth_path" ]; then
        local temp_config
        temp_config=$(mktemp -d)
        cp "$auth_path" "$temp_config/config.json"
        export DOCKER_CONFIG="$temp_config"
        return 0
    else
        echo "WARNING: Oras credentials not found at ${auth_path}" >&2
        return 1
    fi
}

# Push a directory as a gzipped tarball to an OCI registry using oras.
# The tarball is created in /tmp and cleaned up after push.
#
# Args:
#   $1 - source_dir: Directory to tar and push
#   $2 - quay_repo: OCI repository (e.g., quay.io/org/repo)
#   $3 - tag: Image tag
#   $4 - artifact_type: OCI artifact type (optional, default: application/vnd.konflux.logs.v1+tar)
#   $5 - tarball_prefix: Prefix for paths inside tarball (optional, default: tag name)
#
# Returns:
#   0 on success, 1 on failure
#
# Prints:
#   Full OCI reference on success
#
# Example:
#   oras_push_tarball /tmp/logs quay.io/my/repo pipeline-123-logs
oras_push_tarball() {
    local source_dir=$1
    local quay_repo=$2
    local tag=$3
    local artifact_type=${4:-"application/vnd.konflux.logs.v1+tar"}
    local tarball_prefix=${5:-"$tag"}

    if [ ! -d "$source_dir" ]; then
        echo "ERROR: Source directory does not exist: ${source_dir}" >&2
        return 1
    fi

    local tarball_name="${tag}.tar.gz"
    local full_ref="${quay_repo}:${tag}"

    # Create tarball with path transformation
    if ! tar czf "/tmp/${tarball_name}" --transform "s,^,${tarball_prefix}/," -C "$source_dir" .; then
        echo "ERROR: Failed to create tarball" >&2
        return 1
    fi

    # Push to registry
    if ( cd /tmp && oras push --no-tty \
        --artifact-type "$artifact_type" \
        "$full_ref" \
        "$tarball_name" ); then
        rm -f "/tmp/${tarball_name}"
        echo "$full_ref"
        return 0
    else
        echo "ERROR: Failed to push tarball to ${full_ref}" >&2
        rm -f "/tmp/${tarball_name}"
        return 1
    fi
}

# Pull an OCI artifact from a registry and extract any tarballs found.
# Automatically handles .tar.gz extraction and cleanup.
#
# Args:
#   $1 - quay_repo: OCI repository (e.g., quay.io/org/repo)
#   $2 - tag: Image tag
#   $3 - output_dir: Directory where contents should be extracted
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   oras_pull_tarball quay.io/my/repo pipeline-123-logs /tmp/extracted
oras_pull_tarball() {
    local quay_repo=$1
    local tag=$2
    local output_dir=$3

    if [ -z "$quay_repo" ] || [ -z "$tag" ] || [ -z "$output_dir" ]; then
        echo "ERROR: Missing required arguments to oras_pull_tarball" >&2
        return 1
    fi

    mkdir -p "$output_dir"

    local ref="${quay_repo}:${tag}"
    local tmpdir
    tmpdir=$(mktemp -d)

    # Pull artifact
    if ! oras pull --no-tty -o "$tmpdir" "$ref" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1
    fi

    # Extract any tarballs found
    local found_tarball=false
    for tarball in "$tmpdir"/*.tar.gz; do
        if [ -f "$tarball" ]; then
            tar xzf "$tarball" -C "$output_dir" 2>/dev/null || true
            found_tarball=true
        fi
    done

    # Copy any remaining non-tarball files
    find "$tmpdir" -type f ! -name "*.tar.gz" -exec cp {} "$output_dir/" \; 2>/dev/null || true

    rm -rf "$tmpdir"

    if [ "$found_tarball" = false ]; then
        # No tarball found, but pull succeeded - might be individual files
        return 0
    fi

    return 0
}
