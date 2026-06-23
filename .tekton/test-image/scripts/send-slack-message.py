#!/usr/bin/env python3
"""Send Slack notification with task details for GitOps Catalog E2E tests.

Environment variables:
  SLACK_WEBHOOK_URL       - Slack incoming webhook URL
  PIPELINE_RUN_NAME       - Tekton PipelineRun name
  AGGREGATE_STATUS        - Overall pipeline status (Succeeded/Failed/etc.)
  LOG_URL                 - Konflux UI link for this pipeline run
  QUAY_REPO               - OCI repo for log artifacts
  QUAY_CREDENTIALS_PATH   - Path to .dockerconfigjson for oras
  TASK_NAMES              - Space-separated task names that have log artifacts
"""
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime


def run_cmd(cmd, timeout=30):
    """Run a shell command and return stdout, or None on failure."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def get_task_runs(pipeline_run_name):
    """Query TaskRuns for timing, status, and result information."""
    raw = run_cmd(
        f"oc get taskruns -l tekton.dev/pipelineRun={pipeline_run_name} -o json"
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
    run_cmd(f"mkdir -p {tmpdir}")

    if run_cmd(f"oras pull --no-tty -o {tmpdir} {ref} 2>/dev/null") is None:
        run_cmd(f"rm -rf {tmpdir}")
        return None

    log_file = run_cmd(f"find {tmpdir} -name '*.log' -type f 2>/dev/null | head -1")
    if not log_file:
        run_cmd(f"rm -rf {tmpdir}")
        return None

    tail = run_cmd(f"tail -n {lines} {log_file}")
    run_cmd(f"rm -rf {tmpdir}")
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

    config_block = build_config_block(task_runs)
    if config_block:
        blocks.append(config_block)

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
    webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")
    pipeline_run_name = os.environ.get("PIPELINE_RUN_NAME", "")
    aggregate_status = os.environ.get("AGGREGATE_STATUS", "Unknown")
    log_url = os.environ.get("LOG_URL", "")
    quay_repo = os.environ.get("QUAY_REPO", "")
    quay_creds = os.environ.get("QUAY_CREDENTIALS_PATH", "")
    task_names_str = os.environ.get("TASK_NAMES", "")

    if not webhook_url:
        logging.error("SLACK_WEBHOOK_URL is not set")
        return 1

    # Setup oras credentials
    if quay_creds and os.path.isfile(quay_creds):
        tmpdir = tempfile.mkdtemp()
        shutil.copy2(quay_creds, os.path.join(tmpdir, "config.json"))
        os.environ["DOCKER_CONFIG"] = tmpdir

    loggable_tasks = set(task_names_str.split()) if task_names_str else set()
    task_runs = get_task_runs(pipeline_run_name)

    blocks = build_blocks(
        pipeline_run_name, aggregate_status, log_url, quay_repo, task_runs, loggable_tasks
    )

    fallback = f"GitOps Catalog E2E {pipeline_run_name}: {aggregate_status}"
    ret = send_slack_message(webhook_url, blocks, fallback)
    if ret:
        print(ret)

    return 0


if __name__ == "__main__":
    sys.exit(main())
