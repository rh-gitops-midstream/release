#!/usr/bin/env python3
"""Verify that all images referenced by the installed CSV are available
at their mirror locations (from IDMS on the cluster).

Environment variables:
  KUBECONFIG   (required)
  NAMESPACE    Operator namespace (default: openshift-gitops-operator)
  TARGET_ARCH  e.g. arm64, amd64 (auto-detected from cluster if unset)
  IDMS_FILE    Path to images-mirror-set.yaml (falls back to cluster IDMS)

Exit codes:
  0  All images verified (or only skips)
  1  One or more images failed verification
"""

import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


def run_cmd(cmd):
    return subprocess.run(
        cmd, shell=True, capture_output=True, text=True, timeout=120,
    )


def detect_target_arch():
    arch = os.environ.get("TARGET_ARCH")
    if arch:
        return arch
    result = run_cmd(
        "oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'",
    )
    return result.stdout.strip("'\" \n") if result.returncode == 0 else "amd64"


def get_installed_csv(namespace):
    result = run_cmd(
        f"oc get subscription -n {namespace}"
        f" -o jsonpath='{{.items[0].status.installedCSV}}'",
    )
    csv_name = result.stdout.strip("'\" \n")
    if result.returncode != 0 or not csv_name:
        print(f"ERROR: No installed CSV found in namespace {namespace}")
        sys.exit(1)
    return csv_name


def get_related_images(namespace, csv_name):
    result = run_cmd(
        f"oc get csv {csv_name} -n {namespace}"
        f" -o jsonpath='{{range .spec.relatedImages[*]}}{{.image}}{{\"\\n\"}}{{end}}'",
    )
    images = [line.strip("'\" ") for line in result.stdout.strip().splitlines() if line.strip()]
    return images


def build_mirror_map(namespace, idms_file):
    mirror_map = {}

    if idms_file and Path(idms_file).is_file():
        if yaml is None:
            print("ERROR: PyYAML required for IDMS_FILE parsing but not installed")
            sys.exit(1)
        print(f"Loading mirrors from file: {idms_file}")
        with open(idms_file) as f:
            data = yaml.safe_load(f)
        for entry in data.get("spec", {}).get("imageDigestMirrors", []):
            mirrors = entry.get("mirrors", [])
            if mirrors:
                mirror_map[entry["source"]] = mirrors[0]
    else:
        print("Loading mirrors from cluster IDMS...")
        result = run_cmd("oc get imagedigestmirrorset -o json")
        if result.returncode == 0 and result.stdout.strip():
            try:
                data = json.loads(result.stdout)
                for item in data.get("items", []):
                    for entry in item.get("spec", {}).get("imageDigestMirrors", []):
                        mirrors = entry.get("mirrors", [])
                        if mirrors:
                            mirror_map[entry["source"]] = mirrors[0]
            except json.JSONDecodeError:
                print("WARNING: Could not parse IDMS JSON from cluster")

    return mirror_map


def find_auth_file():
    for path in [
        "/quay-pull-credentials/.dockerconfigjson",
        "/quay-credentials/.dockerconfigjson",
    ]:
        if Path(path).is_file():
            return path
    return None


def check_manifest_arch(image_ref, auth_file, target_arch):
    """Inspect a manifest and return (is_ok, not_found, detail_string)."""
    auth_args = f"--authfile={auth_file}" if auth_file else ""
    result = run_cmd(f"skopeo inspect --raw {auth_args} docker://{image_ref}")
    if result.returncode != 0:
        return False, True, "image not found at mirror"

    try:
        manifest = json.loads(result.stdout)
    except json.JSONDecodeError:
        return True, False, "single-arch manifest"

    media_type = str(manifest.get("mediaType", manifest.get("schemaVersion", "")))
    if "manifest.list" in media_type or "image.index" in media_type:
        archs = [
            p.get("platform", {}).get("architecture", "?")
            for p in manifest.get("manifests", [])
        ]
        if target_arch in archs:
            return True, False, f"{target_arch} in: {','.join(archs)}"
        return False, False, f"missing {target_arch} (available: {','.join(archs)})"

    return True, False, "single-arch manifest"


def main():
    namespace = os.environ.get("NAMESPACE", "openshift-gitops-operator")
    idms_file = os.environ.get("IDMS_FILE")

    target_arch = detect_target_arch()
    print(f"Target architecture: {target_arch}")

    csv_name = get_installed_csv(namespace)
    print(f"Installed CSV: {csv_name}")

    images = get_related_images(namespace, csv_name)
    if not images:
        print(f"WARNING: No relatedImages found in CSV {csv_name}")
        sys.exit(0)
    print(f"Found {len(images)} related images in CSV")

    mirror_map = build_mirror_map(namespace, idms_file)
    if not mirror_map:
        print("WARNING: No mirror mappings found")
        print("Images will be pulled directly from source registries")
    print(f"\nMirror mappings loaded: {len(mirror_map)} entries")

    auth_file = find_auth_file()

    passed = 0
    failed = 0
    skipped = 0

    for image in images:
        repo, _, digest = image.partition("@")

        mirror_repo = mirror_map.get(repo)
        if not mirror_repo:
            print(f"  SKIP [no mirror] {repo}")
            skipped += 1
            continue

        check_ref = f"{mirror_repo}@{digest}"
        ok, not_found, detail = check_manifest_arch(check_ref, auth_file, target_arch)

        if ok:
            print(f"  OK   [mirror] {repo} ({detail})")
            passed += 1
        else:
            print(f"  FAIL [mirror] {repo} — {detail}")
            print(f"         ref: {check_ref}")
            if not_found:
                print(f"         source: {image}")
            failed += 1

    print()
    print("=" * 42)
    print(f"Image verification: {passed} OK, {failed} FAILED, {skipped} SKIPPED (no mirror)")
    print("=" * 42)

    if failed > 0:
        print(f"ERROR: {failed} image(s) are not available at their expected locations.")
        print("The operator will fail to create workload pods for these images.")
        sys.exit(1)


if __name__ == "__main__":
    main()
