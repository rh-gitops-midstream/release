#!/bin/bash
# Utilities for collecting pod logs from Kubernetes/OpenShift namespaces.
# Source this file to use these functions in log collection scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/collect-pod-logs.sh"
#   collect_pod_logs openshift-gitops /tmp/logs
#   collect_pod_logs_with_tail openshift-gitops /tmp/snapshots 100

# Collect full logs from all pods in a namespace.
# Creates numbered log files for each pod with all container logs.
#
# Args:
#   $1 - namespace: Namespace to collect logs from
#   $2 - output_dir: Directory where log files should be written
#   $3 - include_description: Set to "true" to include pod description (optional, default: false)
#
# Returns:
#   0 on success (always succeeds, errors are non-fatal)
#
# Output files:
#   <output_dir>/01-<podname>.log
#   <output_dir>/02-<podname>.log
#   ...
#
# File format:
#   === Pod: <name> ===
#   === Namespace: <namespace> ===
#   === Collection Time: <timestamp> ===
#
#   [--- Pod Description --- (if include_description=true)]
#
#   --- Container: <container> ---
#   <logs>
#
#   --- Container: <container> (previous) ---
#   <previous logs if available>
#
# Example:
#   collect_pod_logs openshift-gitops /tmp/cluster-logs
#   collect_pod_logs openshift-gitops /tmp/cluster-logs true  # with descriptions
collect_pod_logs() {
    local namespace=$1
    local output_dir=$2
    local include_description=${3:-false}

    if [ -z "$namespace" ] || [ -z "$output_dir" ]; then
        echo "ERROR: collect_pod_logs requires namespace and output_dir" >&2
        return 1
    fi

    mkdir -p "$output_dir"

    local count=0
    oc get pods -n "$namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null | while read -r pod; do
        count=$((count + 1))
        local log_file="${output_dir}/$(printf '%02d' ${count})-${pod}.log"

        {
            echo "=== Pod: ${pod} ==="
            echo "=== Namespace: ${namespace} ==="
            echo "=== Collection Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ==="
            echo ""

            if [ "$include_description" = "true" ]; then
                echo "--- Pod Description ---"
                oc describe pod "$pod" -n "$namespace" 2>&1 || true
                echo ""
            fi

            oc get pod "$pod" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
                echo "--- Container: ${container} ---"
                oc logs "$pod" -c "$container" -n "$namespace" 2>&1 || echo "(no logs available)"
                echo ""

                echo "--- Container: ${container} (previous) ---"
                oc logs "$pod" -c "$container" -n "$namespace" --previous 2>&1 || echo "(no previous logs)"
                echo ""
            done
        } > "$log_file"
    done || true

    return 0
}

# Collect tail of logs from all pods in a namespace.
# Similar to collect_pod_logs but only retrieves the last N lines per container.
# Useful for periodic snapshots where full logs would be too large.
#
# Args:
#   $1 - namespace: Namespace to collect logs from
#   $2 - output_dir: Directory where log files should be written
#   $3 - tail_lines: Number of lines to retrieve (default: 100)
#
# Returns:
#   0 on success (always succeeds, errors are non-fatal)
#
# Example:
#   collect_pod_logs_with_tail openshift-gitops /tmp/snapshot-123 50
collect_pod_logs_with_tail() {
    local namespace=$1
    local output_dir=$2
    local tail_lines=${3:-100}

    if [ -z "$namespace" ] || [ -z "$output_dir" ]; then
        echo "ERROR: collect_pod_logs_with_tail requires namespace and output_dir" >&2
        return 1
    fi

    mkdir -p "$output_dir"

    oc get pods -n "$namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null | while read -r pod; do
        local log_file="${output_dir}/${pod}.log"

        {
            echo "=== Pod: ${pod} ==="
            echo "=== Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ==="
            echo ""

            oc get pod "$pod" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
                echo "--- Container: ${container} ---"
                oc logs "$pod" -c "$container" -n "$namespace" --tail="$tail_lines" 2>&1 || echo "(no logs available)"
                echo ""
            done
        } > "$log_file"
    done || true

    return 0
}

# Collect description and logs for a specific pod.
# Includes full pod description (events, status, etc.) plus container logs.
#
# Args:
#   $1 - pod_name: Name of the pod
#   $2 - namespace: Namespace containing the pod
#   $3 - output_file: Path to output file
#
# Returns:
#   0 on success, 1 if pod not found
#
# Example:
#   collect_single_pod_logs openshift-gitops-server-abc123 openshift-gitops /tmp/server.log
collect_single_pod_logs() {
    local pod_name=$1
    local namespace=$2
    local output_file=$3

    if [ -z "$pod_name" ] || [ -z "$namespace" ] || [ -z "$output_file" ]; then
        echo "ERROR: collect_single_pod_logs requires pod_name, namespace, and output_file" >&2
        return 1
    fi

    if ! oc get pod "$pod_name" -n "$namespace" &>/dev/null; then
        echo "ERROR: Pod $pod_name not found in namespace $namespace" >&2
        return 1
    fi

    {
        echo "=== Pod: ${pod_name} ==="
        echo "=== Namespace: ${namespace} ==="
        echo "=== Collection Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC") ==="
        echo ""

        echo "--- Pod Description ---"
        oc describe pod "$pod_name" -n "$namespace" 2>&1 || true
        echo ""

        oc get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.containers[]?.name' 2>/dev/null | while read -r container; do
            echo "--- Container: ${container} ---"
            oc logs "$pod_name" -c "$container" -n "$namespace" 2>&1 || echo "(no logs available)"
            echo ""

            echo "--- Container: ${container} (previous) ---"
            oc logs "$pod_name" -c "$container" -n "$namespace" --previous 2>&1 || echo "(no previous logs)"
            echo ""
        done
    } > "$output_file"

    return 0
}
