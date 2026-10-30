#!/usr/bin/env python3
from pathlib import Path
from ruamel.yaml import YAML
import argparse
import re
import subprocess
import json
import sys

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 100000
yaml.indent(mapping=2, sequence=4, offset=2)

parser = argparse.ArgumentParser()
parser.add_argument("--nightly", action="store_true", help="Stamp nightly additional-tags label in catalog Dockerfiles")
args = parser.parse_args()

try:
    subprocess.run(["skopeo", "--version"], check=True, capture_output=False)
except FileNotFoundError:
    print("[error] 'skopeo' is not installed. Please install skopeo >= 1.18.0.")
    sys.exit(1)


def stamp_nightly_labels(catalog_dir: Path, build: str, version: str) -> None:
    """Add/update konflux.additional-tags label in each per-OCP Dockerfile."""
    y_stream = ".".join(version.split(".")[:2])   # e.g. "1.22"
    build_no_v = build.lstrip("v")                # e.g. "1.22.4-1"
    for dockerfile in sorted(catalog_dir.glob("*/Dockerfile")):
        ocp = dockerfile.parent.name              # e.g. "v4.19"
        label_value = (
            f"{ocp}-{build}-nightly"
            f" {ocp}-{y_stream}-nightly"
            f" {ocp}-{version}-nightly"
            f" {ocp}-{build_no_v}-nightly"
        )
        label_line = f'LABEL konflux.additional-tags="{label_value}"'

        content = dockerfile.read_text()
        if "konflux.additional-tags" in content:
            updated = re.sub(
                r'LABEL konflux\.additional-tags="[^"]*"',
                label_line,
                content,
            )
        else:
            updated = content.rstrip("\n") + f"\n{label_line}\n"

        if updated != content:
            dockerfile.write_text(updated)
        print(f"Stamped nightly label in {dockerfile}: {label_value}")

def get_digest(image: str) -> str:
    print(f"Fetching sha256 digest for {image}...")
    output = subprocess.run(
        ["skopeo", "inspect", "--override-os", "linux", "--override-arch", "amd64", f"docker://{image}"],
        capture_output=True, text=True, check=True
    )
    digest = json.loads(output.stdout)["Digest"]
    return digest

RELEASE_CONFIG_FILE = Path("config.yaml")
CATALOG_CONFIG_FILE = Path("catalog/config.yaml")

release_config = yaml.load(RELEASE_CONFIG_FILE.read_text())
catalog_config = yaml.load(CATALOG_CONFIG_FILE.read_text())

olm = release_config.get("release", {}).get("olm", {})

name = olm.get("name", "").strip('"\'')
replaces = olm.get("replaces", "").strip('"\'')
skip_range = olm.get("skip-range", "").strip('"\'')
channel = re.sub(r'\blatest\b,?', '', olm.get("channel", "").strip('"\'')).lstrip(',')  # Remove 'latest' from channel list

# Bundle image
tag = release_config.get('release', {}).get('konflux', {}).get('branch', 'latest')

# For the main branch, derive replaces dynamically from the latest channel in the catalog
if tag == "main":
    for ch in catalog_config.get("channels", []):
        if ch.get("name") == "latest":
            versions = ch.get("versions", [])
            if versions:
                def parse_ver(v):
                    m = re.search(r'v(\d+)\.(\d+)\.(\d+)', v.get("name", ""))
                    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)
                latest_entry = max(versions, key=parse_ver)
                replaces = latest_entry["name"]
                print(f"main branch: dynamically set replaces={replaces} from latest channel")
            break
base = "quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle"   # TODO: read from config.yaml
image = f"{base}:{tag}"
digest =  get_digest(image)
bundle = f"{base}@{digest}"

version_entry = {
    "name": name,
    "replaces": replaces,
    "skipRange": skip_range,
    "bundle": bundle
}

# Check if channel exist in catalog config
existing_channel = None
for ch in catalog_config.get("channels", []):
    if ch.get("name") == channel:
        existing_channel = ch
        break

if existing_channel is None:
    # Create new channel entry
    new_channel = {
        "name": channel,
        "versions": [version_entry]
    }
    catalog_config.setdefault("channels", []).append(new_channel)
else:
    # Update existing channel entry
    versions = existing_channel.get("versions", [])
    for i, v in enumerate(versions):
        if v.get("name") == name:
            versions[i] = version_entry
            break
    else:
        versions.append(version_entry)

with CATALOG_CONFIG_FILE.open('w') as f:
    yaml.dump(catalog_config, f)

print(f"Updated catalog configuration in {CATALOG_CONFIG_FILE}")

if args.nightly:
    build = Path("BUILD").read_text().strip()
    version = str(release_config.get("release", {}).get("version", "")).strip("'\"")
    stamp_nightly_labels(Path("catalog"), build, version)