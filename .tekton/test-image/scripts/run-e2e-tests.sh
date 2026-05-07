#!/bin/bash
set -x

# Environment variables expected:
# - TEST_REPO_URL (optional, defaults to the pre-baked repo remote)
# - BRANCH
# - TEST_DIR
# - TIMEOUT
# - PROCS
# - KUBECONFIG

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

CACHE_DIR=$(mktemp -d)
export GOCACHE="${CACHE_DIR}/go-cache"
export GOMODCACHE="${CACHE_DIR}/go-mod"
mkdir -p "$GOCACHE" "$GOMODCACHE"

oc status

# --- Ensure argocd CLI is available (some tests call `argocd login` etc.) ---
# Extract the Konflux-built argocd binary from the same image the operator deployed.
# The pipeline pod is x86_64 while cluster nodes are arm64, so we can't copy from
# a running pod — we pull the image for the local arch via oc image extract.
if ! command -v argocd &>/dev/null; then
  ARGOCD_IMAGE=$(oc get deployment openshift-gitops-repo-server -n openshift-gitops \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [[ -n "$ARGOCD_IMAGE" ]]; then
    echo "Extracting argocd CLI from ${ARGOCD_IMAGE}..."
    EXTRACT_AUTH_DIR=$(mktemp -d)
    oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | \
      base64 -d > "${EXTRACT_AUTH_DIR}/config.json" 2>/dev/null || true

    ARGOCD_BIN_DIR=$(mktemp -d)
    EXTRACTED=false
    for bin_path in /usr/local/bin/argocd /usr/bin/argocd; do
      if DOCKER_CONFIG="${EXTRACT_AUTH_DIR}" oc image extract "${ARGOCD_IMAGE}" \
          --path "${bin_path}:${ARGOCD_BIN_DIR}/" --confirm 2>/dev/null; then
        if [[ -f "${ARGOCD_BIN_DIR}/argocd" ]]; then
          EXTRACTED=true
          break
        fi
      fi
    done
    rm -rf "${EXTRACT_AUTH_DIR}"

    if [[ "$EXTRACTED" == "true" ]]; then
      chmod +x "${ARGOCD_BIN_DIR}/argocd"
      if "${ARGOCD_BIN_DIR}/argocd" version --client --short 2>/dev/null; then
        export PATH="${ARGOCD_BIN_DIR}:${PATH}"
        echo "argocd CLI installed: $(argocd version --client --short)"
      else
        echo "WARNING: Extracted argocd binary is not executable on this arch"
        file "${ARGOCD_BIN_DIR}/argocd" 2>/dev/null || true
        rm -rf "${ARGOCD_BIN_DIR}"
      fi
    else
      echo "WARNING: Could not extract argocd binary from ${ARGOCD_IMAGE}"
      rm -rf "${ARGOCD_BIN_DIR}"
    fi
  else
    echo "WARNING: openshift-gitops-repo-server not found, argocd CLI unavailable"
  fi
fi

cd /testsuites/gitops-operator/ || exit 1
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/rh-gitops-release-qa/gitops-operator.git}"
git remote set-url origin "${TEST_REPO_URL}" 2>/dev/null || git remote add origin "${TEST_REPO_URL}"
git fetch origin
git clean -fd
git checkout -B "${BRANCH}" "origin/${BRANCH}"

# shellcheck source=/dev/null
source /usr/local/bin/go-cache.sh
go_cache_pull "operator-${BRANCH}"

GINKGO_ARGS=()
if [[ -n "${GINKGO_SKIP:-}" ]]; then
  GINKGO_ARGS+=("--skip=${GINKGO_SKIP}")
  echo "Skipping tests matching: ${GINKGO_SKIP}"
fi

# Enable parallel mode only when PROCS > 1
PARALLEL_FLAG=""
if [[ "${PROCS:-1}" -gt 1 ]]; then
  PARALLEL_FLAG="-p"
fi

TEST_EXIT=0
/testsuites/gitops-operator/bin/ginkgo -timeout "${TIMEOUT}" ${PARALLEL_FLAG} -procs="${PROCS}" --no-color -v --trace -r \
    "${GINKGO_ARGS[@]}" \
    --junit-report="${RESULTS_DIR}/junit-results.xml" \
    --json-report="${RESULTS_DIR}/test-results.json" \
    "${TEST_DIR}/." || TEST_EXIT=$?

go_cache_push "operator-${BRANCH}"

exit $TEST_EXIT
