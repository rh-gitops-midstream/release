#!/usr/bin/env python3
"""Send Slack notification with task details for GitOps Catalog E2E tests.

Environment variables:
  SLACK_WEBHOOK_URL       - Slack incoming webhook URL
  PIPELINE_RUN_NAME       - Tekton PipelineRun name
  AGGREGATE_STATUS        - Overall pipeline status (Succeeded/Failed/etc.)
  LOG_URL                 - Konflux UI link for this pipeline run
  QUAY_REPO               - OCI repo for log artifacts
  TASK_NAMES              - Space-separated task names that have log artifacts
  SHARED_DIR              - Path to shared volume with test-results.json (default: /shared)
"""
import json
import logging
import os
import subprocess
import sys
import urllib.request
from datetime import datetime


def run_cmd(args, timeout=30, verbose=False):
    """Run a command (as an argument list) and return stdout, or None on failure."""
    try:
        result = subprocess.run(
            args, shell=False, capture_output=True, text=True, timeout=timeout
        )
        if verbose or result.returncode != 0:
            logging.info(f"CMD: {args}")
            logging.info(f"  RC: {result.returncode}")
            if result.stdout:
                logging.info(f"  STDOUT: {result.stdout[:500]}")
            if result.stderr:
                logging.info(f"  STDERR: {result.stderr[:500]}")
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception as e:
        logging.error(f"CMD exception: {args}: {e}")
        return None


def get_test_results():
    """Read test results from the shared volume (written by collect-and-upload-logs)."""
    shared_dir = os.environ.get("SHARED_DIR", "/shared")
    path = os.path.join(shared_dir, "test-results.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logging.warning(f"Failed to read test results from {path}: {e}")
        return None


def get_build_metadata():
    """Read build metadata from the shared volume (written by collect-build-metadata.sh)."""
    shared_dir = os.environ.get("SHARED_DIR", "/shared")
    path = os.path.join(shared_dir, "build-metadata.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logging.warning(f"Failed to read build metadata from {path}: {e}")
        return None


def get_task_runs(pipeline_run_name):
    """Query TaskRuns for timing, status, and result information."""
    raw = run_cmd(
        ["oc", "get", "taskruns", "-l", f"tekton.dev/pipelineRun={pipeline_run_name}", "-o", "json"]
    )
    if not raw:
        return {}

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}

    tasks = {}
    for item in data.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        task_name = labels.get("tekton.dev/pipelineTask", "unknown")

        status = item.get("status", {})
        start_time = status.get("startTime")
        completion_time = status.get("completionTime")

        conditions = status.get("conditions", [])
        task_status = "Unknown"
        if conditions:
            reason = conditions[0].get("reason", "")
            cond_status = conditions[0].get("status", "")
            if cond_status == "True":
                task_status = "Succeeded"
            elif reason in ("Failed", "TaskRunTimeout"):
                task_status = "Failed"
            else:
                task_status = reason or "Unknown"

        duration = ""
        if start_time and completion_time:
            try:
                start = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
                end = datetime.fromisoformat(completion_time.replace("Z", "+00:00"))
                total_secs = int((end - start).total_seconds())
                if total_secs >= 3600:
                    duration = f"{total_secs // 3600}h {(total_secs % 3600) // 60}m {total_secs % 60}s"
                elif total_secs >= 60:
                    duration = f"{total_secs // 60}m {total_secs % 60}s"
                else:
                    duration = f"{total_secs}s"
            except Exception:
                pass
        elif start_time:
            duration = "running"

        results = {}
        for r in status.get("results", []):
            results[r.get("name", "")] = r.get("value", "")

        tasks[task_name] = {
            "status": task_status,
            "duration": duration,
            "results": results,
        }

    return tasks


def get_failed_task_log_tail(quay_repo, pipeline_run_name, task_name, lines=20):
    """Pull a failed task's log artifact and return the tail."""
    ref = f"{quay_repo}:{pipeline_run_name}-task-{task_name}"
    tmpdir = f"/tmp/slack-logs-{task_name}"
    run_cmd(["mkdir", "-p", tmpdir])

    if run_cmd(["oras", "pull", "--no-tty", "-o", tmpdir, ref]) is None:
        run_cmd(["rm", "-rf", tmpdir])
        return None

    log_file = run_cmd(["find", tmpdir, "-name", "*.log", "-type", "f"])
    if not log_file:
        run_cmd(["rm", "-rf", tmpdir])
        return None
    # When find returns multiple matches take only the first one
    log_file = log_file.splitlines()[0]

    tail = run_cmd(["tail", "-n", str(lines), log_file])
    run_cmd(["rm", "-rf", tmpdir])
    return tail


def build_config_block(task_runs):
    """Build a block showing pipeline configuration and actual runtime values."""
    test_script = os.environ.get("TEST_SCRIPT", "")
    test_repo_url = os.environ.get("TEST_REPO_URL", "")
    test_repo_branch = os.environ.get("TEST_REPO_BRANCH", "")
    ocp_requested = os.environ.get("OPENSHIFT_VERSION", "")
    operator_channel = os.environ.get("OPERATOR_CHANNEL", "")
    fips = os.environ.get("FIPS_ENABLED", "")

    ocp_actual = (
        task_runs.get("provision-cluster", {}).get("results", {}).get("resolvedVersion")
    )
    installed_csv = (
        task_runs.get("install-operator", {}).get("results", {}).get("installedCSV")
    )

    lines = []
    if test_script:
        lines.append(f"*Test suite:* `{test_script}`")
    if test_repo_url:
        repo_short = test_repo_url.rstrip("/").rsplit("/", 2)[-2:]
        repo_label = "/".join(repo_short).replace(".git", "")
        branch_part = f" @ `{test_repo_branch}`" if test_repo_branch else ""
        lines.append(f"*Test repo:* `{repo_label}`{branch_part}")
    if ocp_requested:
        if ocp_actual and ocp_actual != ocp_requested:
            lines.append(f"*OpenShift:* `{ocp_requested}` -> `{ocp_actual}`")
        else:
            lines.append(f"*OpenShift:* `{ocp_requested}`")
    if installed_csv:
        lines.append(f"*Operator:* `{installed_csv}`")
    if operator_channel:
        lines.append(f"*Channel:* `{operator_channel}`")
    if fips == "true":
        lines.append("*FIPS:* enabled")

    if not lines:
        return None

    return {
        "type": "section",
        "text": {"type": "mrkdwn", "text": "\n".join(lines)},
    }


def build_blocks(
    pipeline_run_name, aggregate_status, log_url, quay_repo, task_runs, loggable_tasks
):
    """Build Slack Block Kit blocks for the notification."""
    # Derive status from actual test results when available, not pipeline aggregate
    test_data = get_test_results()
    if test_data is not None:
        if test_data.get("total", 0) > 0 and test_data.get("failed", 0) == 0 and test_data.get("errors", 0) == 0:
            aggregate_status = "Succeeded"
        elif test_data.get("failed", 0) > 0 or test_data.get("errors", 0) > 0:
            aggregate_status = "Failed"

    status_emoji = (
        ":white_check_mark:" if aggregate_status == "Succeeded" else ":x:"
    )

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"GitOps Catalog E2E: {pipeline_run_name}",
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"{status_emoji} Pipeline finished: *{aggregate_status}*",
            },
        },
    ]

    # Add test summary from shared volume
    if test_data:
        summary = test_data.get("summary", "")
        if summary:
            blocks.append(
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f":test_tube: *Test Results:* {summary}",
                    },
                }
            )
        failed_tests = test_data.get("failedTests", [])
        if failed_tests:
            names = failed_tests[:15]
            text = ":x: *Failed tests:*\n" + "\n".join(f"• `{t}`" for t in names)
            if len(failed_tests) > 15:
                text += f"\n_...and {len(failed_tests) - 15} more_"
            blocks.append(
                {
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": text},
                }
            )

    config_block = build_config_block(task_runs)
    if config_block:
        blocks.append(config_block)

    build_meta = get_build_metadata()
    if build_meta:
        labels = {
            "build": "Build", "argocd": "Argo CD", "dex": "Dex",
            "redis": "Redis", "kustomize": "Kustomize", "helm": "Helm",
            "gitLfs": "git-lfs", "agent": "Agent",
        }
        parts = [f"*{labels.get(k, k)}:* `{v}`" for k, v in build_meta.items() if v]
        if parts:
            blocks.append({
                "type": "section",
                "text": {"type": "mrkdwn", "text": ":package: " + "  |  ".join(parts)},
            })

    # Task list with status and timing
    if task_runs:
        task_order = [
            "parse-metadata",
            "build-ginkgo-test-image",
            "provision-eaas-space",
            "provision-cluster",
            "install-operator",
            "test-operator",
        ]

        lines = []
        failed_tasks = []
        seen = set()

        for name in task_order:
            info = task_runs.get(name)
            if not info:
                continue
            seen.add(name)
            icon = {
                "Succeeded": ":white_check_mark:",
                "Failed": ":x:",
            }.get(info["status"], ":hourglass_flowing_sand:")
            if info["status"] == "Failed":
                failed_tasks.append(name)
            dur = f"  ({info['duration']})" if info["duration"] else ""
            lines.append(f"{icon}  `{name}`{dur}")

        # Any tasks not in our predefined order
        for name, info in sorted(task_runs.items()):
            if name in seen:
                continue
            icon = {
                "Succeeded": ":white_check_mark:",
                "Failed": ":x:",
            }.get(info["status"], ":hourglass_flowing_sand:")
            if info["status"] == "Failed":
                failed_tasks.append(name)
            dur = f"  ({info['duration']})" if info["duration"] else ""
            lines.append(f"{icon}  `{name}`{dur}")

        blocks.append(
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": "*Tasks:*\n" + "\n".join(lines)},
            }
        )

        # Log tails for failed tasks that have artifacts
        for task_name in failed_tasks:
            if task_name not in loggable_tasks or not quay_repo:
                continue
            tail = get_failed_task_log_tail(quay_repo, pipeline_run_name, task_name)
            if not tail:
                continue
            # Slack block text limit is ~3000 chars
            if len(tail) > 2800:
                tail = tail[-2800:]
            blocks.append({"type": "divider"})
            blocks.append(
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f":page_facing_up: *`{task_name}` (last 20 lines):*\n```\n{tail}\n```",
                    },
                }
            )

    # Links
    blocks.append({"type": "divider"})
    links_parts = []
    if log_url:
        links_parts.append(f":technologist: <{log_url}|View in Konflux UI>")
    if quay_repo and pipeline_run_name:
        links_parts.append(
            f":open_file_folder: `oras pull {quay_repo}:{pipeline_run_name}-logs`"
        )
    if links_parts:
        blocks.append(
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": "\n".join(links_parts)},
            }
        )

    return blocks


def send_slack_message(webhook_url, blocks, fallback_text):
    """Post a Slack message via incoming webhook."""
    msg = {"text": fallback_text, "blocks": blocks}
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(msg).encode(),
        headers={"Content-type": "application/json"},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        return resp.read().decode()
    except Exception as e:
        logging.error(f"Failed to send Slack message: {e}")
        return ""


def main():
    # Configure logging to stderr (will appear in pod logs)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s',
        stream=sys.stderr
    )

    logging.info("=== Starting send-slack-message.py ===")

    webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")
    pipeline_run_name = os.environ.get("PIPELINE_RUN_NAME", "")
    aggregate_status = os.environ.get("AGGREGATE_STATUS", "Unknown")
    log_url = os.environ.get("LOG_URL", "")
    quay_repo = os.environ.get("QUAY_REPO", "")
    task_names_str = os.environ.get("TASK_NAMES", "")

    logging.info(f"Environment:")
    logging.info(f"  PIPELINE_RUN_NAME: {pipeline_run_name}")
    logging.info(f"  AGGREGATE_STATUS: {aggregate_status}")
    logging.info(f"  QUAY_REPO: {quay_repo}")
    logging.info(f"  TASK_NAMES: {task_names_str}")
    logging.info(f"  LOG_URL: {log_url}")

    if not webhook_url:
        logging.error("SLACK_WEBHOOK_URL is not set")
        return 1

    loggable_tasks = set(task_names_str.split()) if task_names_str else set()
    logging.info(f"Loggable tasks: {loggable_tasks}")

    # Setup oras credentials for pulling per-task log artifacts
    quay_creds = os.environ.get("QUAY_CREDENTIALS_PATH", "/quay-credentials/.dockerconfigjson")
    if quay_repo and os.path.isfile(quay_creds):
        import shutil
        import tempfile
        tmpdir = tempfile.mkdtemp()
        shutil.copy2(quay_creds, os.path.join(tmpdir, "config.json"))
        os.environ["DOCKER_CONFIG"] = tmpdir

    logging.info("Fetching task runs from cluster...")
    task_runs = get_task_runs(pipeline_run_name)
    logging.info(f"Found {len(task_runs)} task runs")

    logging.info("Building Slack blocks...")
    blocks = build_blocks(
        pipeline_run_name, aggregate_status, log_url, quay_repo, task_runs, loggable_tasks
    )
    logging.info(f"Built {len(blocks)} blocks")

    fallback = f"GitOps Catalog E2E {pipeline_run_name}: {aggregate_status}"
    logging.info(f"Sending Slack message...")
    ret = send_slack_message(webhook_url, blocks, fallback)
    logging.info(f"Slack API response: {ret}")
    if ret:
        print(ret)

    logging.info("=== send-slack-message.py completed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
