#!/bin/bash
set -u

# Environment variables expected:
# - KUBECONFIG
# - PIPELINE_RUN_NAME
# - NAMESPACE
# - QUAY_REPO
# - QUAY_CREDENTIALS_PATH (path to .dockerconfigjson)
# - TASK_NAMES (space-separated list of task names whose logs to pull, e.g. "install-operator test-operator")

LOGS_DIR="logs"
IMAGE_TAG="${PIPELINE_RUN_NAME}-logs"
TASK_NAMES="${TASK_NAMES:-}"
ERRORS=()

collect_error() {
    ERRORS+=("$1")
    echo "WARNING: $1"
}

echo "=========================================="
echo "Collecting logs and debug info"
echo "Pipeline: ${PIPELINE_RUN_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "=========================================="

# Configure Docker credentials for oras (needed for both pulling task logs and final push)
if [ -f "${QUAY_CREDENTIALS_PATH}" ]; then
    TEMP_DOCKER_CONFIG="$(mktemp -d)"
    cp "${QUAY_CREDENTIALS_PATH}" "$TEMP_DOCKER_CONFIG/config.json"
    export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
else
    collect_error "Quay credentials not found at ${QUAY_CREDENTIALS_PATH}"
fi

# Create logs directory structure
mkdir -p "${LOGS_DIR}/tasks"
mkdir -p "${LOGS_DIR}/cluster-pods"
mkdir -p "${LOGS_DIR}/debug"
mkdir -p "${LOGS_DIR}/results"

# -----------------------------------------------------------
# 1. Pull per-task log artifacts uploaded by earlier tasks
# -----------------------------------------------------------
if [ -n "${TASK_NAMES}" ]; then
    echo ""
    echo "=========================================="
    echo "Pulling per-task log artifacts"
    echo "=========================================="
    for TASK_NAME in ${TASK_NAMES}; do
        TASK_TAG="${PIPELINE_RUN_NAME}-task-${TASK_NAME}"
        TASK_REF="${QUAY_REPO}:${TASK_TAG}"
        TASK_DIR="${LOGS_DIR}/tasks/${TASK_NAME}"
        mkdir -p "${TASK_DIR}"

        echo "Pulling task logs: ${TASK_REF}"
        PULL_DIR="/tmp/pull-${TASK_NAME}"
        mkdir -p "${PULL_DIR}"
        if oras pull --no-tty -o "${PULL_DIR}" "${TASK_REF}" 2>/dev/null; then
            # Extract any tarballs pulled from oras
            for tarball in "${PULL_DIR}"/*.tar.gz; do
                [ -f "$tarball" ] && tar xzf "$tarball" -C "${TASK_DIR}" && rm -f "$tarball"
            done
            # Copy any remaining files (non-tarball artifacts)
            find "${PULL_DIR}" -type f -exec cp {} "${TASK_DIR}/" \; 2>/dev/null || true
            # Move test result files to the results directory
            find "${TASK_DIR}" -name "*.xml" -exec cp {} "${LOGS_DIR}/results/" \; 2>/dev/null || true
            find "${TASK_DIR}" -name "*.json" -exec cp {} "${LOGS_DIR}/results/" \; 2>/dev/null || true
        else
            collect_error "Could not pull logs for task ${TASK_NAME} (may not have uploaded)"
        fi
        rm -rf "${PULL_DIR}"
    done
fi

# -----------------------------------------------------------
# 2-4. Collect cluster debug info (only if cluster is reachable)
# -----------------------------------------------------------
CLUSTER_REACHABLE=false
if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG:-}" ]; then
    export KUBECONFIG
    if oc whoami --request-timeout=10s &>/dev/null; then
        CLUSTER_REACHABLE=true
    else
        collect_error "Cluster unreachable (kubeconfig exists but oc commands fail)"
    fi
else
    collect_error "Kubeconfig not available (file: ${KUBECONFIG:-unset})"
fi

if [ "$CLUSTER_REACHABLE" = true ]; then
    echo ""
    echo "Collecting cluster debug information..."

    {
        echo "--- Cluster Version ---"
        oc version 2>&1 || true
        echo ""
        echo "--- Cluster Operators ---"
        oc get co 2>&1 || true
        echo ""
        echo "--- Nodes ---"
        oc get nodes -o wide 2>&1 || true
    } > "${LOGS_DIR}/debug/cluster-info.txt" 2>&1 || collect_error "Failed to collect cluster info"

    echo "Collecting namespace debug information..."

    {
        echo "--- All Resources in ${NAMESPACE} ---"
        oc get all -n "${NAMESPACE}" -o wide 2>&1 || true
        echo ""
        echo "--- Subscriptions ---"
        oc get subscriptions -n "${NAMESPACE}" -o yaml 2>&1 || true
        echo ""
        echo "--- ClusterServiceVersions ---"
        oc get csv -n "${NAMESPACE}" -o yaml 2>&1 || true
        echo ""
        echo "--- InstallPlans ---"
        oc get installplans -n "${NAMESPACE}" -o yaml 2>&1 || true
    } > "${LOGS_DIR}/debug/namespace-resources.txt" 2>&1 || collect_error "Failed to collect namespace resources"

    {
        echo "--- Events ---"
        oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 || true
    } > "${LOGS_DIR}/debug/events.txt" 2>&1 || collect_error "Failed to collect events"

    {
        echo "--- CatalogSource ---"
        oc get catalogsource -n openshift-marketplace -o yaml 2>&1 || true
    } > "${LOGS_DIR}/debug/catalogsource.txt" 2>&1 || collect_error "Failed to collect catalogsource"

    echo "Collecting pod logs..."
    TASK_COUNT=0
    oc get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null | while read -r pod; do
        TASK_COUNT=$((TASK_COUNT + 1))
        TASK_LOG_FILE="${LOGS_DIR}/cluster-pods/$(printf '%02d' ${TASK_COUNT})-${pod}.log"

        {
            echo "=== Pod: ${pod} ==="
            echo "=== Namespace: ${NAMESPACE} ==="
            echo "=== Collection Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ==="
            echo ""

            echo "--- Pod Description ---"
            oc describe pod "${pod}" -n "${NAMESPACE}" 2>&1 || true
            echo ""

            oc get pod "${pod}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
                echo "--- Container: ${container} ---"
                oc logs "${pod}" -c "${container}" -n "${NAMESPACE}" 2>&1 || echo "(no logs available)"
                echo ""

                echo "--- Container: ${container} (previous) ---"
                oc logs "${pod}" -c "${container}" -n "${NAMESPACE}" --previous 2>&1 || echo "(no previous logs)"
                echo ""
            done
        } > "${TASK_LOG_FILE}"
    done || collect_error "Failed to collect some pod logs"
else
    echo "Skipping cluster debug collection (cluster unreachable)"
fi

# -----------------------------------------------------------
# 5. Parse JUnit test summary (if available)
# -----------------------------------------------------------
TEST_SUMMARY=""
JUNIT_FILE="${LOGS_DIR}/results/junit-results.xml"
if [ -f "$JUNIT_FILE" ]; then
    TESTS=$(grep -oP 'tests="\K[0-9]+' "$JUNIT_FILE" | head -1 || echo "?")
    FAILURES=$(grep -oP 'failures="\K[0-9]+' "$JUNIT_FILE" | head -1 || echo "?")
    SKIPPED=$(grep -oP 'skipped="\K[0-9]+' "$JUNIT_FILE" | head -1 || echo "0")
    ERRORS_COUNT=$(grep -oP 'errors="\K[0-9]+' "$JUNIT_FILE" | head -1 || echo "0")
    TEST_SUMMARY="Tests: ${TESTS} total, $((TESTS - FAILURES - SKIPPED - ERRORS_COUNT)) passed, ${FAILURES} failed, ${SKIPPED} skipped, ${ERRORS_COUNT} errors"
fi

# -----------------------------------------------------------
# 6. Create README
# -----------------------------------------------------------
{
    echo "Pipeline Run Logs - ${PIPELINE_RUN_NAME}"
    echo "Namespace - ${NAMESPACE}"
    echo "Collected - $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""
    if [ -n "$TEST_SUMMARY" ]; then
        echo "Test Summary: ${TEST_SUMMARY}"
        echo ""
    fi
    echo "Structure:"
    echo "  - tasks/         : stdout/stderr from each pipeline task step"
    echo "  - results/       : test result files (JUnit XML, JSON reports)"
    echo "  - cluster-pods/  : pod logs from the ephemeral cluster"
    echo "  - debug/         : cluster and namespace debug information"
    echo ""
    echo "Files:"
    find "${LOGS_DIR}/" -type f | sort | sed 's/^/  - /'
    echo ""
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo "Collection warnings:"
        for err in "${ERRORS[@]}"; do
            echo "  - ${err}"
        done
        echo ""
    fi
    echo "To extract these logs:"
    echo "  oras pull ${QUAY_REPO}:${IMAGE_TAG}"
    echo "  tar xzf ${PIPELINE_RUN_NAME}-logs.tar.gz"
} > "${LOGS_DIR}/README.txt"

# -----------------------------------------------------------
# 7. Create CLAUDE.md for self-documenting analysis
# -----------------------------------------------------------
cat > "${LOGS_DIR}/CLAUDE.md" << 'CLAUDE_EOF'
# GitOps Operator Integration Test Logs

These logs are from a Konflux pipeline that installs the GitOps operator
on an ephemeral EaaS HyperShift cluster and runs e2e tests.

## Quick diagnosis

1. **Test results**: Check `results/junit-results.xml` for pass/fail summary.
   Count failures: `grep -c 'failure message' results/junit-results.xml`

2. **Test output**: Check `tasks/test-operator/test-operator.log` for test
   stdout/stderr. Search for `FAIL` or `--- FAIL` to find failing tests.

3. **Operator install**: Check `tasks/install-operator/install-operator.log`
   for operator deployment issues.

4. **Pod health**: Check `cluster-pods/` for ArgoCD component logs.

5. **Cluster events**: Check `debug/events.txt` for scheduling, image pull,
   or crash loop issues.

## Common failure patterns

| Symptom | Where to look | Likely cause |
|---------|--------------|--------------|
| `ImagePullBackOff` in events | debug/events.txt, install-operator.log | Pull secret not propagated to HyperShift nodes |
| `exec format error` | test-operator.log | Architecture mismatch (ARM image on x86 or vice versa) |
| Test timeout (no results) | test-operator.log (last test name) | A test hung — check which test was running last |
| `FailedScheduling` | debug/events.txt | Node selector mismatch or insufficient resources |
| `MachineConfig` failures | test-operator.log | MCO not available on HyperShift — should be in skip list |
| 464/470 argo tests fail | tasks/test-operator/argocd-e2e.log | `argocd-delete` plugin missing — kubectl is wrong binary |
| `connection refused` | test-operator.log | ArgoCD server not ready or port-forward failed |

## File structure

```
logs/
├── CLAUDE.md              ← you are here
├── README.txt             ← pipeline run metadata and test summary
├── tasks/                 ← per-task stdout/stderr from pipeline steps
│   ├── install-operator/  ← operator installation output
│   └── test-operator/     ← test execution output + JUnit/JSON results
├── results/               ← copies of JUnit XML and JSON reports
├── cluster-pods/          ← pod logs from the ephemeral test cluster
└── debug/                 ← cluster state: events, resources, catalog
```

## Analysis workflow

1. Read `README.txt` for the test summary line
2. If tests failed, read the test log to identify which tests failed and why
3. If operator install failed, check install log for image pull or timeout issues
4. Cross-reference with cluster events and pod logs for infrastructure problems
5. Check if failures match known HyperShift limitations (skip list candidates)
CLAUDE_EOF

# -----------------------------------------------------------
# 8. Upload combined logs to Quay
# -----------------------------------------------------------
echo ""
echo "=========================================="
echo "Uploading combined logs to Quay"
echo "=========================================="

FULL_OCI_REF="${QUAY_REPO}:${IMAGE_TAG}"

echo "Uploading logs to ${FULL_OCI_REF}..."
TARBALL="${PIPELINE_RUN_NAME}-logs.tar.gz"
tar czf "/tmp/${TARBALL}" --transform "s,^,${PIPELINE_RUN_NAME}/," -C "${LOGS_DIR}" .

if ( cd /tmp && oras push --no-tty \
    --artifact-type "application/vnd.konflux.logs.v1+tar" \
    "${FULL_OCI_REF}" \
    "${TARBALL}" ); then
    echo "Successfully pushed combined log artifact to ${FULL_OCI_REF}"
else
    echo "ERROR: Failed to push log artifact to ${FULL_OCI_REF}"
    echo "Logs were collected locally but could not be uploaded."
fi

echo ""
echo "Contents:"
find "${LOGS_DIR}/" -type f | sort | head -50
echo ""
echo "Total size:"
du -sh "${LOGS_DIR}/"
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Collection completed with ${#ERRORS[@]} warning(s)."
fi
