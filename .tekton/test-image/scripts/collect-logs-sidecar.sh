#!/bin/bash
set -u

# Environment variables expected:
# - KUBECONFIG_NAME
# - PIPELINE_RUN_NAME
# - BRANCH_NAME (used as the task artifact name, e.g. "logs" → tag: ${PIPELINE_RUN_NAME}-task-logs)
# - NAMESPACE
# - QUAY_REPO

LOGS_DIR="logs"
IMAGE_TAG="${PIPELINE_RUN_NAME}-task-${BRANCH_NAME}"
FULL_OCI_REF="${QUAY_REPO}:${IMAGE_TAG}"
COLLECT_INTERVAL=30
UPLOAD_EVERY=10  # upload every 10 snapshots (10 * 30s = 5 min)

TIMEOUT=300
ELAPSED=0

if [ "${KUBECONFIG_NAME}" = "auto" ]; then
    while [ $ELAPSED -lt $TIMEOUT ]; do
        KUBECONFIG_PATH=$(find /credentials -name "*kubeconfig" -type f 2>/dev/null | head -1)
        if [ -n "${KUBECONFIG_PATH:-}" ]; then break; fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
else
    KUBECONFIG_PATH="/credentials/${KUBECONFIG_NAME}"
    while [ ! -f "${KUBECONFIG_PATH}" ] && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
fi

CLUSTER_AVAILABLE=false
if [ -n "${KUBECONFIG_PATH:-}" ] && [ -f "${KUBECONFIG_PATH:-}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
    if oc whoami --request-timeout=10s &>/dev/null; then
        CLUSTER_AVAILABLE=true
    else
        echo "WARNING: Kubeconfig found but cluster is unreachable"
    fi
else
    echo "WARNING: Kubeconfig not found after ${TIMEOUT}s — will skip cluster log collection"
    echo "Contents of /credentials:"
    ls -la /credentials/ 2>/dev/null || true
fi

# Configure Docker credentials for oras (needed for periodic uploads)
AUTH_PATH="/quay-credentials/.dockerconfigjson"
if [ -f "$AUTH_PATH" ]; then
    TEMP_DOCKER_CONFIG="$(mktemp -d)"
    cp "$AUTH_PATH" "$TEMP_DOCKER_CONFIG/config.json"
    export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
fi

mkdir -p "${LOGS_DIR}"

# --- Helper functions ---

collect_snapshot() {
    if [ "$CLUSTER_AVAILABLE" != true ]; then return 0; fi
    if ! oc get pods -n "${NAMESPACE}" &>/dev/null; then
        return 0
    fi

    local timestamp
    timestamp=$(date +%s)
    local snapshot_dir="${LOGS_DIR}/snapshot-${timestamp}"
    mkdir -p "${snapshot_dir}"

    oc get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null | while read -r pod; do
        local pod_log_file="${snapshot_dir}/${pod}.log"
        echo "=== Pod: ${pod} ===" > "${pod_log_file}"
        echo "=== Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ===" >> "${pod_log_file}"
        echo "" >> "${pod_log_file}"

        oc get pod "${pod}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
            echo "--- Container: ${container} ---" >> "${pod_log_file}"
            oc logs "${pod}" -c "${container}" -n "${NAMESPACE}" --tail=100 >> "${pod_log_file}" 2>&1 || echo "(no logs available)" >> "${pod_log_file}"
            echo "" >> "${pod_log_file}"
        done
    done || true
}

collect_final() {
    if [ "$CLUSTER_AVAILABLE" != true ]; then return 0; fi

    FINAL_DIR="${LOGS_DIR}/final"
    mkdir -p "${FINAL_DIR}"

    local count=0
    oc get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null | while read -r pod; do
        count=$((count + 1))
        local log_file="${FINAL_DIR}/$(printf '%02d' ${count})-${pod}.log"
        {
            echo "=== Pod: ${pod} ==="
            echo "=== Namespace: ${NAMESPACE} ==="
            echo "=== Collection Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ==="
            echo ""
            oc get pod "${pod}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
                echo "--- Container: ${container} ---"
                oc logs "${pod}" -c "${container}" -n "${NAMESPACE}" 2>&1 || echo "(no logs available)"
                echo ""
            done
        } > "${log_file}"
    done || true
}

generate_readme() {
    {
        echo "Sidecar Logs - ${PIPELINE_RUN_NAME}"
        echo "Namespace - ${NAMESPACE}"
        echo "Collected - $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo "Cluster available: ${CLUSTER_AVAILABLE}"
        echo "Upload #${UPLOAD_COUNT}"
        echo ""
        echo "Structure:"
        echo "  - snapshot-* directories: periodic snapshots during test execution"
        echo "  - final/ directory: complete logs at test completion (if present)"
        echo ""
        echo "Files:"
        find "${LOGS_DIR}/" -type f -name "*.log" 2>/dev/null | sort | sed 's/^/  - /'
        echo ""
        echo "To extract these logs:"
        echo "  oras pull ${QUAY_REPO}:${IMAGE_TAG}"
        echo "  tar xzf ${PIPELINE_RUN_NAME}-task-${BRANCH_NAME}-logs.tar.gz"
    } > "${LOGS_DIR}/README.txt"
}

upload_logs() {
    UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
    generate_readme

    local tarball="${PIPELINE_RUN_NAME}-task-${BRANCH_NAME}-logs.tar.gz"
    tar czf "/tmp/${tarball}" --transform "s,^,${PIPELINE_RUN_NAME}-task-${BRANCH_NAME}/," -C "${LOGS_DIR}" .

    if ( cd /tmp && oras push --no-tty \
        --artifact-type "application/vnd.konflux.logs.v1+tar" \
        "${FULL_OCI_REF}" \
        "${tarball}" ); then
        echo "Sidecar upload #${UPLOAD_COUNT} pushed to ${FULL_OCI_REF} ($(du -h "/tmp/${tarball}" | cut -f1))"
    else
        echo "WARNING: Sidecar upload #${UPLOAD_COUNT} failed"
    fi
    rm -f "/tmp/${tarball}"
}

# --- Main loop ---

SNAPSHOT_COUNT=0
UPLOAD_COUNT=0

while true; do
    collect_snapshot
    SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))

    if (( SNAPSHOT_COUNT % UPLOAD_EVERY == 0 )); then
        upload_logs
    fi

    sleep ${COLLECT_INTERVAL} &
    wait $! || break
done

# Final comprehensive collection + upload (best effort)
echo "Sidecar exiting — collecting final logs and uploading"
collect_final
upload_logs
