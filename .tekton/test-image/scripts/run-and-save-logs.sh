#!/bin/bash
set -o pipefail

# Wrapper that runs a command, tees output to a log file, and uploads to Quay.
# The finally step later pulls these per-task artifacts and combines them.
#
# Environment variables expected:
# - TASK_LOG_NAME         - name for the log artifact (e.g. "install-operator")
# - PIPELINE_RUN_NAME    - pipeline run name, used in the artifact tag
# - QUAY_REPO            - quay repository for log uploads
# - QUAY_CREDENTIALS_PATH - path to .dockerconfigjson (default: /quay-credentials/.dockerconfigjson)
#
# Usage: run-and-save-logs.sh <command> [args...]

QUAY_CREDENTIALS_PATH="${QUAY_CREDENTIALS_PATH:-/quay-credentials/.dockerconfigjson}"
LOG_DIR="/tmp/task-logs"
LOG_FILE="${LOG_DIR}/${TASK_LOG_NAME}.log"

mkdir -p "${LOG_DIR}"

# Run the command, tee to log file, preserve exit code
"$@" 2>&1 | tee "${LOG_FILE}"
EXIT_CODE=${PIPESTATUS[0]}

# Collect any test result files (JUnit XML, JSON reports) produced by the command
for pattern in /tmp/task-logs/*.xml /tmp/task-logs/*.json; do
    if [ -f "$pattern" ]; then
        echo "Found test result file: $pattern"
    fi
done

# Upload logs to Quay if credentials are available
if [ -n "${QUAY_REPO}" ] && [ -n "${PIPELINE_RUN_NAME}" ] && [ -n "${TASK_LOG_NAME}" ]; then
    echo ""
    echo "=========================================="
    echo "Uploading task logs: ${TASK_LOG_NAME}"
    echo "=========================================="

    if [ -f "${QUAY_CREDENTIALS_PATH}" ]; then
        TEMP_DOCKER_CONFIG="$(mktemp -d)"
        cp "${QUAY_CREDENTIALS_PATH}" "${TEMP_DOCKER_CONFIG}/config.json"
        export DOCKER_CONFIG="${TEMP_DOCKER_CONFIG}"
    else
        echo "Warning: Quay credentials not found at ${QUAY_CREDENTIALS_PATH}, skipping upload"
        exit "${EXIT_CODE}"
    fi

    IMAGE_TAG="${PIPELINE_RUN_NAME}-task-${TASK_LOG_NAME}"
    FULL_OCI_REF="${QUAY_REPO}:${IMAGE_TAG}"

    # Tar and push log directory (oras expects files, not directories)
    TARBALL="${TASK_LOG_NAME}-logs.tar.gz"
    tar czf "/tmp/${TARBALL}" -C "${LOG_DIR}" .
    ( cd /tmp && oras push --no-tty \
        --artifact-type "application/vnd.konflux.logs.v1+tar" \
        "${FULL_OCI_REF}" \
        "${TARBALL}" ) || echo "Warning: failed to upload task logs"

    echo "Task logs uploaded to ${FULL_OCI_REF}"
fi

exit "${EXIT_CODE}"
