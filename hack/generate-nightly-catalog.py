#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_DIR = ROOT / "catalog"
CATALOG_REMOTE = "rh-gitops-midstream/catalog"
CATALOG_URL_TEMPLATE = "https://x-access-token:{token}@github.com/{repo}.git"
NIGHTLY_BRANCH = "build/nightly-catalog"


def run(cmd, **kwargs):
    defaults = {"check": True, "text": True}
    defaults.update(kwargs)
    print(f">>> {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    return subprocess.run(cmd, **defaults)


def run_output(cmd, **kwargs):
    result = run(cmd, capture_output=True, **kwargs)
    return result.stdout.strip()


def get_token():
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("[error] GH_TOKEN environment variable is required.")
        sys.exit(1)
    return token


def catalog_url(token):
    return CATALOG_URL_TEMPLATE.format(token=token, repo=CATALOG_REMOTE)


def clone_and_prepare_branch(token):
    """Clone the catalog repo and set up the nightly branch.

    If the nightly branch exists, check it out and rebase onto main.
    If rebase fails, start fresh from main.
    """
    url = catalog_url(token)

    if CATALOG_DIR.exists():
        run(["rm", "-rf", str(CATALOG_DIR)])

    # Check if the nightly branch exists on the remote
    result = subprocess.run(
        ["git", "ls-remote", "--heads", url, NIGHTLY_BRANCH],
        capture_output=True, text=True
    )
    branch_exists = NIGHTLY_BRANCH in (result.stdout or "")

    if branch_exists:
        print(f"Nightly branch '{NIGHTLY_BRANCH}' exists. Cloning and rebasing onto main...")
        run(["git", "clone", url, str(CATALOG_DIR)])
        os.chdir(CATALOG_DIR)
        run(["git", "checkout", NIGHTLY_BRANCH])

        rebase = subprocess.run(
            ["git", "rebase", "origin/main"],
            capture_output=True, text=True
        )
        if rebase.returncode != 0:
            print("Rebase conflict detected. Starting fresh from main.")
            run(["git", "rebase", "--abort"])
            run(["git", "checkout", "main"])
            run(["git", "branch", "-D", NIGHTLY_BRANCH])
            run(["git", "checkout", "-b", NIGHTLY_BRANCH])
    else:
        print(f"Nightly branch '{NIGHTLY_BRANCH}' does not exist. Creating from main...")
        run(["git", "clone", url, str(CATALOG_DIR)])
        os.chdir(CATALOG_DIR)
        run(["git", "checkout", "-b", NIGHTLY_BRANCH])

    run(["git", "config", "user.name", "github-actions[bot]"])
    run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"])
    os.chdir(ROOT)


def generate_catalog():
    """Run catalog generation and template rendering."""
    run(["make", "nightly-catalog"], cwd=ROOT)


def has_changes():
    os.chdir(CATALOG_DIR)
    diff = subprocess.run(["git", "diff", "--quiet"], capture_output=True)
    cached = subprocess.run(["git", "diff", "--cached", "--quiet"], capture_output=True)
    os.chdir(ROOT)
    return diff.returncode != 0 or cached.returncode != 0


def commit_and_push(token, branch, build):
    """Commit catalog changes and force-push the nightly branch."""
    os.chdir(CATALOG_DIR)

    run(["git", "add", "-A"])
    run(["git", "commit", "-m",
         f"chore(nightly): update catalog channel for {branch} (build {build})"])
    run(["git", "push", catalog_url(token), NIGHTLY_BRANCH, "--force-with-lease"])

    os.chdir(ROOT)


def create_or_update_pr(branch, build):
    """Create a new nightly PR or update the existing one."""
    timestamp = run_output(["date", "-u", "+%Y-%m-%d %H:%M UTC"])

    existing_pr = ""
    try:
        existing_pr = run_output([
            "gh", "pr", "list",
            "--repo", CATALOG_REMOTE,
            "--head", NIGHTLY_BRANCH,
            "--state", "open",
            "--json", "number",
            "--jq", ".[0].number // empty"
        ])
    except subprocess.CalledProcessError:
        pass

    if existing_pr:
        print(f"Updating existing nightly PR #{existing_pr}...")
        run([
            "gh", "pr", "comment", existing_pr,
            "--repo", CATALOG_REMOTE,
            "--body", f"Updated with catalog changes from **{branch}** (build `{build}`) at {timestamp}."
        ])
        run([
            "gh", "pr", "edit", existing_pr,
            "--repo", CATALOG_REMOTE,
            "--title", f"chore(nightly): consolidated catalog updates (latest: {build})"
        ])
    else:
        print("Creating new nightly PR...")
        body = (
            "This PR contains consolidated nightly catalog updates.\n"
            "\n"
            "Each nightly build appends its channel update as a separate commit.\n"
            "\n"
            f"**Latest build:** `{build}`\n"
            f"**Latest channel:** `{branch}`\n"
            f"**Last updated:** {timestamp}\n"
            "\n"
            "Please **do not merge** this PR. It is auto-generated to trigger a catalog build from Konflux.\n"
            "Separate PRs will be created for production bundle updates.\n"
            "\n"
            "Automatically generated by GitHub Actions."
        )
        run([
            "gh", "pr", "create",
            "--repo", CATALOG_REMOTE,
            "--head", NIGHTLY_BRANCH,
            "--base", "main",
            "--title", f"chore(nightly): consolidated catalog updates (build {build})",
            "--body", body,
            "--label", "nightly",
            "--label", "do-not-merge"
        ])


def main():
    branch = os.environ.get("TARGET_BRANCH", "")
    if not branch:
        print("[error] TARGET_BRANCH environment variable is required.")
        sys.exit(1)

    build_file = ROOT / "BUILD"
    if not build_file.exists():
        print("[error] BUILD file not found.")
        sys.exit(1)
    build = build_file.read_text().strip()

    token = get_token()

    clone_and_prepare_branch(token)
    generate_catalog()

    if not has_changes():
        print(f"No catalog changes for branch {branch}. Skipping.")
        return

    commit_and_push(token, branch, build)
    create_or_update_pr(branch, build)

    print("Nightly catalog update complete.")


if __name__ == "__main__":
    main()