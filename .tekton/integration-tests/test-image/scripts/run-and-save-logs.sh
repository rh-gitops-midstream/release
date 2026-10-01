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

# shellcheck source=./lib/oras-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/oras-helpers.sh"

QUAY_CREDENTIALS_PATH="${QUAY_CREDENTIALS_PATH:-/quay-credentials/.dockerconfigjson}"
LOG_DIR="/tmp/task-logs"
LOG_FILE="${LOG_DIR}/${TASK_LOG_NAME}.log"

mkdir -p "${LOG_DIR}"

# Save execution context before running the command
{
    echo "# Environment variables captured at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "# Pipeline: ${PIPELINE_RUN_NAME}"
    echo "# Task: ${TASK_LOG_NAME}"
    echo "# Command: $*"
    echo ""

    # Export all environment variables (excluding credentials and sensitive data)
    env | grep -v -E '^(PATH=|HOME=|USER=|HOSTNAME=|PWD=|OLDPWD=|LS_COLORS=|DOCKER_CONFIG=|.*PASSWORD.*=|.*SECRET.*=|.*TOKEN.*=|.*KEY.*=)' | sort
} > "${LOG_DIR}/env.sh"

# Copy KUBECONFIG if it exists and is a file
if [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]]; then
    cp "${KUBECONFIG}" "${LOG_DIR}/kubeconfig"
    echo "Saved KUBECONFIG to ${LOG_DIR}/kubeconfig"
fi

# Create a reproduce.sh script
{
    echo '#!/bin/bash'
    echo '# Script to help reproduce this task execution'
    echo '#'
    echo "# Pipeline: ${PIPELINE_RUN_NAME}"
    echo "# Task: ${TASK_LOG_NAME}"
    echo "# Captured: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo '#'
    echo '# To use this script:'
    echo '#   1. Extract the logs artifact: oras pull <quay-ref>'
    echo '#      tar xzf <task>-logs.tar.gz'
    echo '#   2. Source the environment: source env.sh'
    echo '#   3. Set KUBECONFIG: export KUBECONFIG=kubeconfig (if present)'
    echo '#   4. Run the command below (adjust paths as needed)'
    echo ''
    echo 'set -x'
    echo ''
    echo "# Original command:"
    echo "$*"
} > "${LOG_DIR}/reproduce.sh"
chmod +x "${LOG_DIR}/reproduce.sh"

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

    if ! setup_oras_auth "${QUAY_CREDENTIALS_PATH}"; then
        echo "Warning: Quay credentials not available, skipping upload"
        exit "${EXIT_CODE}"
    fi

    IMAGE_TAG="${PIPELINE_RUN_NAME}-task-${TASK_LOG_NAME}"

    if UPLOADED_REF=$(oras_push_tarball "${LOG_DIR}" "${QUAY_REPO}" "${IMAGE_TAG}" \
        "application/vnd.konflux.logs.v1+tar" "${TASK_LOG_NAME}-logs"); then
        echo "Task logs uploaded to ${UPLOADED_REF}"
    else
        echo "Warning: failed to upload task logs"
    fi
fi

exit "${EXIT_CODE}"
