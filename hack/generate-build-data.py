#!/usr/bin/env python3
"""Generate build metadata files for a release candidate build.

Usage: python3 hack/generate-build-data.py --commit <sha>
Reads BUILD from ./BUILD and config from ./config.yaml in the current directory.
Writes releases/<version>/candidates/<build>/{COMMIT,BUILD,config.yaml,CHANGELOG.md}.
Prunes old candidates to keep only the last 10.
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

from ruamel.yaml import YAML

yaml = YAML()
yaml.preserve_quotes = True


def parse_build_ver(name):
    """Parse v99.99.99-77 into a sortable tuple (99, 99, 99, 77)."""
    m = re.search(r'v(\d+)\.(\d+)\.(\d+)-(\d+)', name)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0, 0)


def load_config_from_dir(candidate_dir):
    """Return parsed config.yaml stored inside a candidate/production directory."""
    config_file = candidate_dir / "config.yaml"
    if not config_file.exists():
        return None
    return yaml.load(config_file.read_text())


def sources_map(config):
    """Return {path: source_dict} from a config's sources list."""
    return {s["path"]: s for s in config.get("sources", [])} if config else {}


def find_latest_candidate(candidates_dir, exclude=""):
    """Return (dir_name, dir_path) of the most recent candidate, or (None, None)."""
    if not candidates_dir.exists():
        return None, None
    subdirs = [d for d in candidates_dir.iterdir() if d.is_dir() and d.name != exclude]
    if not subdirs:
        return None, None
    subdirs.sort(key=lambda d: parse_build_ver(d.name))
    latest = subdirs[-1]
    return latest.name, latest


def diff_cell(cur_commit, ref_map, path, url):
    """Produce a markdown table cell linking to the GitHub commit diff."""
    if ref_map is None:
        return "—"
    prev = (ref_map.get(path) or {}).get("commit", "")
    if not prev or prev == cur_commit:
        return "no change"
    owner_repo = url.replace("https://github.com/", "")
    if owner_repo.endswith(".git"):
        owner_repo = owner_repo[:-4]
    return f"[changes](https://github.com/{owner_repo}/compare/{prev[:7]}...{cur_commit[:7]})"


def make_table(sources, ref_map):
    """Build a markdown component table for the given reference source map."""
    rows = [
        "| Component | Ref | Diff | Auto-update |",
        "|-----------|-----|------|-------------|",
    ]
    for src in sources:
        path = src["path"]
        component = path.split("/")[-1]
        cur_ref = str(src.get("ref", "")).strip("'\"")
        cur_commit = str(src.get("commit", "")).strip("'\"")
        cur_commit_short = cur_commit[:7] if cur_commit else "?"
        url = str(src.get("url", "")).strip("'\"")
        auto_update = "✓" if src.get("auto-update") else "—"

        component_cell = f"[{component}]({url})" if url else component

        prev_src = (ref_map or {}).get(path, {})
        prev_ref = str(prev_src.get("ref", "")).strip("'\"")
        prev_commit = str(prev_src.get("commit", "")).strip("'\"")
        prev_commit_short = prev_commit[:7] if prev_commit else ""

        if prev_ref and prev_ref != cur_ref:
            ref_cell = f"{prev_ref} ({prev_commit_short}) → {cur_ref} ({cur_commit_short})"
        elif prev_commit_short and prev_commit_short != cur_commit_short:
            ref_cell = f"{cur_ref} ({prev_commit_short} → {cur_commit_short})"
        else:
            ref_cell = f"{cur_ref} ({cur_commit_short})"

        diff = diff_cell(cur_commit, ref_map, path, url)
        rows.append(f"| {component_cell} | {ref_cell} | {diff} | {auto_update} |")
    return "\n".join(rows)


def main():
    parser = argparse.ArgumentParser(description="Generate release candidate build metadata")
    parser.add_argument("--commit", required=True, help="Bundle merge commit SHA")
    parser.add_argument("--snapshot-file", default="", help="Path to Konflux snapshot YAML file to store alongside build metadata")
    args = parser.parse_args()

    commit_sha = args.commit.strip()

    build_file = Path("BUILD")
    if not build_file.exists():
        print("[error] BUILD file not found in current directory.", file=sys.stderr)
        sys.exit(1)
    build = build_file.read_text().strip()

    config_file = Path("config.yaml")
    if not config_file.exists():
        print("[error] config.yaml not found in current directory.", file=sys.stderr)
        sys.exit(1)
    release_config = yaml.load(config_file.read_text())

    version = str(release_config["release"]["version"]).strip("'\"")
    olm = release_config.get("release", {}).get("olm", {})
    replaces = str(olm.get("replaces", "")).strip("'\"")
    sources = release_config.get("sources", [])

    candidates_dir = Path(f"releases/{version}/candidates")
    build_dir = candidates_dir / build

    # ── Write COMMIT, BUILD, config.yaml, and optional SNAPSHOT ─────────────
    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / "COMMIT").write_text(commit_sha + "\n")
    (build_dir / "BUILD").write_text(build + "\n")
    (build_dir / "config.yaml").write_bytes(config_file.read_bytes())
    print(f"Written: {build_dir / 'COMMIT'}")
    print(f"Written: {build_dir / 'BUILD'}")
    print(f"Written: {build_dir / 'config.yaml'}")
    snapshot_file_src = Path(args.snapshot_file.strip()) if args.snapshot_file.strip() else None
    snapshot = ""
    if snapshot_file_src and snapshot_file_src.exists():
        dest = build_dir / "snapshot.yaml"
        dest.write_bytes(snapshot_file_src.read_bytes())
        print(f"Written: {dest}")
        snap_data = yaml.load(snapshot_file_src.read_text())
        snapshot = (snap_data.get("metadata") or {}).get("name", "")

    # ── Section B: Previous build candidate (same version) ───────────────────
    prev_cand_name, prev_cand_dir = find_latest_candidate(candidates_dir, exclude=build)
    prev_cand_sources = None
    if prev_cand_dir is not None:
        prev_cand_cfg = load_config_from_dir(prev_cand_dir)
        prev_cand_sources = sources_map(prev_cand_cfg)

    # ── Section A: Previous release (from olm.replaces) ──────────────────────
    prev_release_ver = None
    prev_release_sources = None
    prev_release_note = ""

    m = re.search(r'v(\d+\.\d+\.\d+)', replaces)
    if m:
        prev_release_ver = m.group(1)
        prev_rel_prod = Path(f"releases/{prev_release_ver}/production")
        prev_rel_cfg = load_config_from_dir(prev_rel_prod)
        prev_release_sources = sources_map(prev_rel_cfg)
        if prev_release_sources is None:
            prev_release_note = (
                "_Previous release production data not available in this repo "
                "(cross-stream upgrade or first build for this version)._\n\n"
            )

    # ── Generate CHANGELOG.md ─────────────────────────────────────────────────
    prev_cand_label = prev_cand_name or "—"
    prev_rel_label = f"v{prev_release_ver}" if prev_release_ver else "—"

    section_a_header = f"## Changes from previous release ({prev_rel_label})"
    section_b_header = f"## Changes from previous build candidate ({prev_cand_label})"

    snapshot_line = f"**Konflux snapshot:** `{snapshot}`  \n" if snapshot else ""
    changelog = (
        f"# Changelog for {build}\n\n"
        f"**Release version:** `{version}`  \n"
        f"**Previous operator release:** `{replaces}`  \n"
        f"**Previous build candidate:** `{prev_cand_label}`  \n"
        f"{snapshot_line}\n"
        f"{section_a_header}\n\n"
        f"{prev_release_note}"
        f"{make_table(sources, prev_release_sources)}\n\n"
        f"{section_b_header}\n\n"
        f"{make_table(sources, prev_cand_sources)}\n"
    )

    changelog_path = build_dir / "CHANGELOG.md"
    changelog_path.write_text(changelog)
    print(f"Written: {changelog_path}")

    # ── Prune: keep last 10 candidates ───────────────────────────────────────
    all_dirs = sorted(
        [d for d in candidates_dir.iterdir() if d.is_dir()],
        key=lambda d: parse_build_ver(d.name)
    )
    for d in all_dirs[:-10]:
        shutil.rmtree(d)
        print(f"Pruned old candidate: {d}")


if __name__ == "__main__":
    main()
