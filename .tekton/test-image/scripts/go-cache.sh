#!/bin/bash
# Go build cache backed by OCI registry via oras.
# Source this file, then call go_cache_pull / go_cache_push.
#
# Usage:
#   source /usr/local/bin/go-cache.sh
#   go_cache_pull "argocd-v2.14"
#   # ... compile ...
#   go_cache_push "argocd-v2.14"
#
# Expects: QUAY_REPO env var, quay credentials at /quay-credentials/.dockerconfigjson

QUAY_REPO="${QUAY_REPO:-quay.io/devtools_gitops/test_image}"

_go_cache_setup_auth() {
    local auth_path="/quay-credentials/.dockerconfigjson"
    if [ -f "$auth_path" ] && [ -z "${DOCKER_CONFIG:-}" ]; then
        local temp_config
        temp_config=$(mktemp -d)
        cp "$auth_path" "$temp_config/config.json"
        export DOCKER_CONFIG="$temp_config"
    fi
}

_go_cache_tag() {
    local suffix="${1:-default}"
    local arch
    arch=$(go env GOARCH 2>/dev/null || echo "amd64")

    local sum_hash="unknown"
    if [ -f "go.sum" ]; then
        sum_hash=$(sha256sum go.sum | cut -c1-12)
    fi

    echo "go-cache-${arch}-${suffix}-${sum_hash}"
}

go_cache_pull() {
    local tag
    tag="${QUAY_REPO}:$(_go_cache_tag "${1:-default}")"

    _go_cache_setup_auth

    local tmpdir
    tmpdir=$(mktemp -d)
    if (cd "$tmpdir" && oras pull --no-tty "$tag" 2>/dev/null); then
        if [ -f "$tmpdir/go-cache.tar.gz" ]; then
            tar xzf "$tmpdir/go-cache.tar.gz" -C / 2>/dev/null || true
            echo "Go cache restored from ${tag}"
        fi
    else
        echo "No Go cache found at ${tag}, building from scratch"
    fi
    rm -rf "$tmpdir"
}

go_cache_push() {
    local tag
    tag="${QUAY_REPO}:$(_go_cache_tag "${1:-default}")"

    _go_cache_setup_auth

    local gocache gomodcache
    gocache=$(go env GOCACHE 2>/dev/null)
    gomodcache=$(go env GOMODCACHE 2>/dev/null)

    local paths=()
    [ -d "$gocache" ] && paths+=("${gocache#/}")
    [ -d "$gomodcache" ] && paths+=("${gomodcache#/}")

    if [ ${#paths[@]} -eq 0 ]; then
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    tar czf "$tmpdir/go-cache.tar.gz" -C / "${paths[@]}" 2>/dev/null || true

    (cd "$tmpdir" && oras push --no-tty \
        --artifact-type "application/vnd.go-cache.v1+tar" \
        "$tag" \
        "go-cache.tar.gz" 2>/dev/null) && \
        echo "Go cache pushed to ${tag}" || \
        echo "WARNING: Failed to push Go cache"

    rm -rf "$tmpdir"
}
