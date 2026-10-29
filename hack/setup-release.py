#!/usr/bin/env python3

from __future__ import annotations

import re
from pathlib import Path

import yaml

BUILD_PATTERN = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)-(?P<build_id>\d+)$")
CONFIG_PATH = Path("config.yaml")
BUILD_PATH = Path("BUILD")
TEKTON_DIR = Path(".tekton")
CONTAINERS_DIR = Path("containers")


def read_release_version(config_path: Path) -> str:
    lines = config_path.read_text(encoding="utf-8").splitlines()

    in_release_block = False
    release_indent = 0
    version = ""

    for line in lines:
        if not in_release_block:
            match_release = re.match(r"^(\s*)release:\s*$", line)
            if match_release:
                in_release_block = True
                release_indent = len(match_release.group(1))
            continue

        if not line.strip() or line.lstrip().startswith("#"):
            continue

        current_indent = len(line) - len(line.lstrip())
        if current_indent <= release_indent:
            break

        match_version = re.match(
            r'^\s*version:\s*["\']?([^"\'\s#]+)["\']?\s*(?:#.*)?$',
            line,
        )
        if match_version:
            version = match_version.group(1).strip()
            break

    if not version:
        raise ValueError(f"Missing 'release.version' in {config_path}")

    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(
            f"Invalid release.version '{version}' in {config_path}. Expected format: x.y.z"
        )

    return version


def parse_build(build_value: str) -> tuple[str, int]:
    match = BUILD_PATTERN.fullmatch(build_value.strip())
    if not match:
        raise ValueError(
            f"Invalid BUILD format '{build_value}'. Expected format: v<version>-<id>"
        )
    return match.group("version"), int(match.group("build_id"))


def compute_new_build(config_version: str, current_build: str) -> str:
    current_version, current_id = parse_build(current_build)
    new_id = current_id if current_version == config_version else 0
    return f"v{config_version}-{new_id}"


def update_build_file(config_path: Path, build_path: Path) -> str:
    config_version = read_release_version(config_path)
    current_build = build_path.read_text(encoding="utf-8").strip()
    new_build = compute_new_build(config_version, current_build)

    if current_build != new_build:
        build_path.write_text(f"{new_build}\n", encoding="utf-8")

    return new_build


def convert_version_to_xy_format(version: str) -> str:
    """Convert version from X.Y.Z format to X-Y format."""
    parts = version.split(".")
    if len(parts) < 2:
        raise ValueError(f"Invalid version format: {version}")
    return f"{parts[0]}-{parts[1]}"


def convert_version_to_xdoty_format(version: str) -> str:
    """Convert version from X.Y.Z format to X.Y format."""
    parts = version.split(".")
    if len(parts) < 2:
        raise ValueError(f"Invalid version format: {version}")
    return f"{parts[0]}.{parts[1]}"


def update_container_dockerfiles_cpe(config_path: Path, containers_dir: Path) -> None:
    """Update cpe labels in containers Dockerfiles to use X.Y release version."""
    config_version = read_release_version(config_path)
    cpe_version = convert_version_to_xdoty_format(config_version)

    dockerfiles = sorted(containers_dir.glob("*/Dockerfile"))
    updated_files = []

    for dockerfile in dockerfiles:
        content = dockerfile.read_text(encoding="utf-8")
        updated_content = re.sub(
            r'(cpe="cpe:/a:redhat:openshift_gitops:)\d+\.\d+(::el\d+")',
            rf'\g<1>{cpe_version}\g<2>',
            content,
        )

        if updated_content != content:
            dockerfile.write_text(updated_content, encoding="utf-8")
            updated_files.append(str(dockerfile))

    if updated_files:
        print(
            "Updated cpe labels in container Dockerfiles: "
            + ", ".join(updated_files)
        )
    else:
        print("No container Dockerfiles needed cpe label updates")


def read_konflux_config(config_path: Path) -> dict:
    """Read the release.konflux section from config.yaml."""
    with open(config_path, encoding="utf-8") as f:
        config = yaml.safe_load(f)
    konflux = config.get("release", {}).get("konflux", {})
    required = ("repo", "branch", "application")
    missing = [k for k in required if k not in konflux]
    if missing:
        raise ValueError(
            f"Missing release.konflux fields {missing} in {config_path}"
        )
    return konflux


def update_tekton_files(config_path: Path, tekton_dir: Path) -> None:
    """Update .tekton YAML files using release.konflux as the authoritative source of target values."""
    config_version = read_release_version(config_path)

    if config_version.startswith("99.99"):
        print("Skipping .tekton updates for development version 99.99.X")
        return

    konflux = read_konflux_config(config_path)
    target_branch = konflux["branch"]           # written directly into target_branch expressions
    target_application = konflux["application"] # written directly into application labels
    source_repo = konflux["repo"]

    # Extract version suffix from application name (e.g. "gitops-1-23" → "1-23")
    app_prefix = "gitops-"
    if not target_application.startswith(app_prefix):
        raise ValueError(
            f"Unexpected release.konflux.application {target_application!r}; "
            f"expected it to start with '{app_prefix}'"
        )
    version_suffix = target_application[len(app_prefix):]

    repo_annotation = source_repo.removesuffix(".git") + "?rev={{revision}}"

    yaml_files = [f for f in tekton_dir.glob("*.yaml") if f.is_file()]
    updated_files = []

    for yaml_file in yaml_files:
        content = yaml_file.read_text(encoding="utf-8")
        updated_content = content

        # Determine the current suffix from this file's application label so we know what to replace
        current_app_match = re.search(
            r'appstudio\.openshift\.io/application:\s+(\S+)', content
        )
        if current_app_match:
            current_app = current_app_match.group(1)
            if current_app.startswith(app_prefix):
                old_suffix = re.escape(current_app[len(app_prefix):])

                updated_content = re.sub(
                    rf'(appstudio\.openshift\.io/component:\s+\S+)-{old_suffix}\b',
                    rf'\1-{version_suffix}',
                    updated_content,
                )
                updated_content = re.sub(
                    rf'(\bname:\s+\S+)-{old_suffix}-(on-(?:pull-request|push))',
                    rf'\1-{version_suffix}-\2',
                    updated_content,
                )
                updated_content = re.sub(
                    rf'(serviceAccountName:\s+\S+)-{old_suffix}\b',
                    rf'\1-{version_suffix}',
                    updated_content,
                )

        # Write application label directly from release.konflux.application
        updated_content = re.sub(
            r'(appstudio\.openshift\.io/application:\s+)\S+',
            rf'\g<1>{target_application}',
            updated_content,
        )

        # Write target_branch directly from release.konflux.branch
        updated_content = re.sub(
            r'(target_branch\s+==\s+")[^"]+(")',
            rf'\g<1>{target_branch}\2',
            updated_content,
        )

        # Update repo annotation from release.konflux.repo
        updated_content = re.sub(
            r'(build\.appstudio\.openshift\.io/repo:\s+)\S+',
            rf'\g<1>{repo_annotation}',
            updated_content,
        )

        if updated_content != content:
            yaml_file.write_text(updated_content, encoding="utf-8")
            updated_files.append(yaml_file.name)

    if updated_files:
        print(f"Updated .tekton files: {', '.join(updated_files)}")
    else:
        print("No .tekton files needed updates")


def main() -> int:
    new_build = update_build_file(CONFIG_PATH, BUILD_PATH)
    print(f"BUILD updated to {new_build}")

    update_tekton_files(CONFIG_PATH, TEKTON_DIR)
    update_container_dockerfiles_cpe(CONFIG_PATH, CONTAINERS_DIR)
    
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
