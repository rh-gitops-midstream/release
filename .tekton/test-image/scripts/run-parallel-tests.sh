#!/bin/bash
set -x

# Parallel ginkgo tests for the gitops-operator.
# Env vars expected: TEST_REPO_URL, BRANCH, KUBECONFIG

export TEST_DIR="${TEST_DIR:-./test/openshift/e2e/ginkgo/parallel}"
export PROCS="${PROCS:-4}"
export TIMEOUT="${TIMEOUT:-90m}"

SKIP_FILE="/usr/local/bin/skip-parallel.txt"
if [[ -f "$SKIP_FILE" ]]; then
  SKIP_PATTERN=$(grep -v '^\s*#' "$SKIP_FILE" | grep -v '^\s*$' | paste -sd '|')
  if [[ -n "$SKIP_PATTERN" ]]; then
    if [[ -n "${GINKGO_SKIP:-}" ]]; then
      export GINKGO_SKIP="${GINKGO_SKIP}|${SKIP_PATTERN}"
    else
      export GINKGO_SKIP="$SKIP_PATTERN"
    fi
  fi
fi

/usr/local/bin/run-e2e-tests.sh
exit $?
