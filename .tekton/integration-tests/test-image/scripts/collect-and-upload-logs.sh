#!/bin/bash
set -u

# Environment variables expected:
# - PIPELINE_RUN_NAME
# - NAMESPACE
# - QUAY_REPO
# - QUAY_CREDENTIALS_PATH (path to .dockerconfigjson)
# - TASK_NAMES (space-separated list of task names whose logs to pull, e.g. "install-operator test-operator")
# - KUBECONFIG (optional, will be auto-detected if not set)

# shellcheck source=./lib/oras-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/oras-helpers.sh"
# shellcheck source=./lib/collect-pod-logs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/collect-pod-logs.sh"

# Find kubeconfig — get-kubeconfig step may have failed (cluster deprovisioned)
if [ -z "${KUBECONFIG:-}" ]; then
    KUBECONFIG=$(find /credentials -name "*kubeconfig" -type f 2>/dev/null | head -1)
    export KUBECONFIG="${KUBECONFIG:-}"
fi

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
if ! setup_oras_auth "${QUAY_CREDENTIALS_PATH}"; then
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
        TASK_DIR="${LOGS_DIR}/tasks/${TASK_NAME}"
        mkdir -p "${TASK_DIR}"

        echo "Pulling task logs: ${QUAY_REPO}:${TASK_TAG}"
        if oras_pull_tarball "${QUAY_REPO}" "${TASK_TAG}" "${TASK_DIR}"; then
            # Move test result files to the results directory
            find "${TASK_DIR}" -name "*.xml" -exec cp {} "${LOGS_DIR}/results/" \; 2>/dev/null || true
            find "${TASK_DIR}" -name "*.json" -exec cp {} "${LOGS_DIR}/results/" \; 2>/dev/null || true
        else
            collect_error "Could not pull logs for task ${TASK_NAME} (may not have uploaded)"
        fi
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
    if ! collect_pod_logs "${NAMESPACE}" "${LOGS_DIR}/cluster-pods" true; then
        collect_error "Failed to collect pod logs"
    fi
else
    echo "Skipping cluster debug collection (cluster unreachable)"
fi

# -----------------------------------------------------------
# 4.5. Collect build metadata (component versions)
# -----------------------------------------------------------
SHARED_DIR="${SHARED_DIR:-/shared}"
if [ "$CLUSTER_REACHABLE" = true ]; then
    echo ""
    echo "Collecting build metadata..."
    /usr/local/bin/collect-build-metadata.sh "${SHARED_DIR}/build-metadata.json" || \
        collect_error "Failed to collect build metadata"
fi

# -----------------------------------------------------------
# 5. Parse JUnit test results (if available)
# -----------------------------------------------------------
TEST_SUMMARY=""
JUNIT_FILE=$(find "${LOGS_DIR}/results" "${SHARED_DIR}/results" -name "*.xml" -type f 2>/dev/null | head -1)
if [ -f "${JUNIT_FILE:-}" ]; then
    echo "Parsing test results from ${JUNIT_FILE}..."
    if python3 /usr/local/bin/parse-test-results.py \
        "${JUNIT_FILE}" "${SHARED_DIR}/test-results.json" 2>&1; then
        TEST_SUMMARY="Tests: $(python3 -c "import json; print(json.load(open('${SHARED_DIR}/test-results.json'))['summary'])")"
    else
        echo "WARNING: Failed to parse JUnit XML"
    fi
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
│   ├── install-operator/
│   │   ├── install-operator.log  ← stdout/stderr
│   │   ├── env.sh                ← environment variables at execution time
│   │   ├── kubeconfig            ← cluster credentials (if present)
│   │   └── reproduce.sh          ← script showing how to reproduce the run
│   └── test-operator/
│       ├── test-operator.log
│       ├── env.sh
│       ├── kubeconfig
│       ├── reproduce.sh
│       └── *.xml, *.json         ← test results (JUnit, JSON)
├── results/               ← copies of JUnit XML and JSON reports
├── cluster-pods/          ← pod logs from the ephemeral test cluster
└── debug/                 ← cluster state: events, resources, catalog
```

## Reproducing a task locally

Each task directory includes:
- **env.sh**: Environment variables (credentials filtered out)
- **kubeconfig**: Cluster credentials (if task had cluster access)
- **reproduce.sh**: Instructions for reproducing the task execution

To reproduce a failed task:
```bash
cd tasks/install-operator/
source env.sh
export KUBECONFIG=kubeconfig
cat reproduce.sh  # Review the original command
```

## Analysis workflow

1. Read `README.txt` for the test summary line
2. If tests failed, read the test log to identify which tests failed and why
3. If operator install failed, check install log for image pull or timeout issues
4. Cross-reference with cluster events and pod logs for infrastructure problems
5. Check if failures match known HyperShift limitations (skip list candidates)
6. Use env.sh + kubeconfig to reproduce the task execution locally
CLAUDE_EOF

# -----------------------------------------------------------
# 8. Upload combined logs to Quay
# -----------------------------------------------------------
echo ""
echo "=========================================="
echo "Uploading combined logs to Quay"
echo "=========================================="

echo "Uploading logs to ${QUAY_REPO}:${IMAGE_TAG}..."

if UPLOADED_REF=$(oras_push_tarball "${LOGS_DIR}" "${QUAY_REPO}" "${IMAGE_TAG}" \
    "application/vnd.konflux.logs.v1+tar" "${PIPELINE_RUN_NAME}"); then
    echo "Successfully pushed combined log artifact to ${UPLOADED_REF}"
else
    echo "ERROR: Failed to push log artifact to ${QUAY_REPO}:${IMAGE_TAG}"
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
