#!/usr/bin/env python3
"""Render results.jsonl into a navigable directory of Markdown files.

Four levels of README are generated so any directory in GitHub shows a
useful at-a-glance summary:

    README.md                                                  top-level overview
    {product}/README.md                                        per-version summary
    {product}/{version}/README.md                              per-OCP summary
    {product}/{version}/ocp-{ocp}/README.md                   per-config matrix
    {product}/{version}/ocp-{ocp}/{variant}/{script}/README.md full run history (leaf)
"""
import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict

MAX_LEAF_RUNS = 10
MAX_HISTORY_ICONS = 4
FAIL_DETAIL_THRESHOLD = 3  # show test names when fewer than this many failures

PRODUCT_DIRS = {
    "gitops-operator-e2e": "gitops-operator",
    "gitops-operator-dast": "gitops-operator-dast",
    "argocd-e2e": "argocd",
}

VARIANTS = ["default", "upgrade", "fips", "fips-upgrade"]

# Canonical order for test-type columns; unknown scripts appear after in alphabetical order
SCRIPT_LABELS = {
    "run-sanity-tests.sh": "sanity",
    "run-sequential-tests-shard1.sh": "sequential-s1",
    "run-sequential-tests-shard2.sh": "sequential-s2",
    "run-parallel-tests.sh": "parallel",
    "run-rollouts-tests.sh": "rollouts",
    "run-ui-e2e-tests.sh": "ui",
    "dast-scan": "dast",
}
SCRIPT_LABEL_ORDER = ["e2e", "sanity", "sequential-s1", "sequential-s2", "parallel", "rollouts", "ui", "dast"]


def get_script_label(script):
    if not script:
        return "e2e"
    basename = os.path.basename(script)
    return SCRIPT_LABELS.get(basename, basename.replace(".sh", ""))


# ── Data loading and grouping ─────────────────────────────────────────────────

def load_records(repo_dir):
    path = os.path.join(repo_dir, "results.jsonl")
    if not os.path.exists(path):
        return []
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def get_version(record):
    csv = record.get("installedCSV", "")
    if csv:
        parts = csv.rsplit(".", 1)
        if len(parts) == 2 and parts[1].startswith("v"):
            return parts[1]
        return csv
    return record.get("argocdVersion", "unknown")


def get_variant(record):
    fips = record.get("fipsEnabled", "false") == "true"
    upgrade = record.get("upgrade", "false") == "true"
    if fips and upgrade:
        return "fips-upgrade"
    if fips:
        return "fips"
    if upgrade:
        return "upgrade"
    return "default"


def get_product_dir(record):
    return PRODUCT_DIRS.get(record.get("pipeline", ""), record.get("pipeline", "unknown"))


def group_records(records):
    """Return dict (product, version, ocp, variant, script_label) -> [records newest-first]."""
    groups = defaultdict(list)
    for r in records:
        script_label = get_script_label(r.get("testScript", ""))
        key = (
            get_product_dir(r),
            get_version(r),
            r.get("openshiftVersion", "unknown"),
            get_variant(r),
            script_label,
        )
        groups[key].append(r)
    for key in groups:
        groups[key].sort(key=lambda r: r.get("timestamp", ""), reverse=True)
    return groups


# ── Status helpers ────────────────────────────────────────────────────────────

def short_test_name(full_name):
    """Extract a compact identifier from a long test name."""
    # Ginkgo: extract 1-031_validate_toolchain style ID
    m = re.search(r"(\d+-\d+[a-zA-Z0-9_]+)", full_name)
    if m:
        return m.group(1)
    # DAST: "classname/[RISK] Alert Name (alertRef=NNN)" → "[RISK] Alert Name"
    m = re.search(
        r"(\[(?:HIGH|MEDIUM|LOW|INFORMATIONAL)\]\s+[^(]+?)(?:\s+\(alertRef=|\s*$)",
        full_name,
    )
    if m:
        name = m.group(1).strip()
        return (name[:40] + "…") if len(name) > 40 else name
    parts = re.split(r"[/: ]+", full_name)
    last = parts[-1].strip()
    return (last[:35] + "…") if len(last) > 35 else last


def status_cell(record):
    """Rich status cell: shows fail count and test names when < FAIL_DETAIL_THRESHOLD."""
    status = record.get("status", "")
    failed_count = (record.get("testsFailed") or 0) + (record.get("testsErrors") or 0)
    failed_tests = record.get("failedTests", [])

    if status == "Succeeded":
        passed = record.get("testsPassed")
        return f"✅ {passed} pass" if passed is not None else "✅ pass"

    if not failed_count:
        return "❌ ERROR"

    if failed_tests and failed_count < FAIL_DETAIL_THRESHOLD:
        names = ", ".join(short_test_name(t) for t in failed_tests[:failed_count])
        return f"❌ {failed_count} fail: {names}"

    return f"❌ {failed_count} fail"


def worst_status_cell(records_list):
    """Pick the worst-status record from a list and return its cell string."""
    if not records_list:
        return "—"
    # Failed > ERROR > Succeeded
    for r in records_list:
        if r.get("status") != "Succeeded":
            return status_cell(r)
    return status_cell(records_list[0])


def linked_status_cell(record):
    """status_cell() wrapped in a markdown link to logUrl when available."""
    cell = status_cell(record)
    url = record.get("logUrl", "")
    return f"[{cell}]({url})" if url else cell


def status_icon(record):
    """Single icon for history sparklines."""
    return "✅" if record.get("status") == "Succeeded" else "❌"


def history_icons(records, skip=1, n=MAX_HISTORY_ICONS):
    """Compact sparkline of the last n runs (skipping the most recent)."""
    icons = [status_icon(r) for r in records[skip : skip + n]]
    return " ".join(icons) if icons else "—"


def build_meta_line(record):
    """One-liner component version string from buildMetadata."""
    bm = record.get("buildMetadata") or {}
    labels = {
        "build": "Build", "argocd": "Argo CD", "dex": "Dex",
        "redis": "Redis", "kustomize": "Kustomize", "helm": "Helm",
        "gitLfs": "git-lfs", "agent": "Agent",
    }
    parts = [f"**{labels.get(k, k)}:** {v}" for k, v in bm.items() if v]
    return ("*Component versions:* " + " | ".join(parts)) if parts else ""


def version_sort_key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-]", v.lstrip("v"))]


def ordered_script_labels(label_set):
    """Return labels in canonical order (SCRIPT_LABEL_ORDER first, then extras alphabetically)."""
    known = [l for l in SCRIPT_LABEL_ORDER if l in label_set]
    extras = sorted(l for l in label_set if l not in SCRIPT_LABEL_ORDER)
    return known + extras


# ── Leaf README (full run history for one variant+testScript) ─────────────────

def render_leaf_readme(records, product, version, ocp, variant, script_label):
    parts = [product, version, f"OCP {ocp}"]
    if variant != "default":
        parts.append(variant.upper())
    if script_label:
        parts.append(script_label)

    lines = [f"# {' / '.join(parts)}", ""]
    lines += [
        "| Date | Status | Passed | Failed | Skipped | Channel | Logs |",
        "|------|--------|--------|--------|---------|---------|------|",
    ]
    for r in records[:MAX_LEAF_RUNS]:
        ts = r.get("timestamp", "")[:10]
        st = status_cell(r)
        passed  = str(r["testsPassed"])  if "testsPassed"  in r else "-"
        failed  = str(r["testsFailed"])  if "testsFailed"  in r else "-"
        skipped = str(r["testsSkipped"]) if "testsSkipped" in r else "-"
        channel = r.get("operatorChannel", "")
        log_parts = []
        if r.get("logUrl"):
            log_parts.append(f"[UI]({r['logUrl']})")
        if r.get("logsArtifact"):
            log_parts.append(f"`oras pull {r['logsArtifact']}`")
        lines.append(
            f"| {ts} | {st} | {passed} | {failed} | {skipped} | {channel} | {' / '.join(log_parts)} |"
        )

    meta = build_meta_line(records[0])
    if meta:
        lines += ["", meta]
    if len(records) > MAX_LEAF_RUNS:
        lines += ["", f"*Showing {MAX_LEAF_RUNS} of {len(records)} runs.*"]
    lines.append("")
    return "\n".join(lines)


# ── OCP-level README (variant × test-type matrix) ────────────────────────────

def render_ocp_readme(cell_map, product, version, ocp, all_records):
    """cell_map: {(variant, script_label): [records newest-first]}

    all_records: full record list used to derive expected columns (historical runs).
    """
    lines = [f"# {product} / {version} / OCP {ocp}", ""]

    # Emit component versions from first available record
    for v in VARIANTS:
        for label in SCRIPT_LABEL_ORDER:
            recs = cell_map.get((v, label), [])
            if recs:
                meta = build_meta_line(recs[0])
                if meta:
                    lines += [meta, ""]
                break
        else:
            continue
        break

    # Determine expected test-type columns from all historical runs for this (product, ocp)
    historical_labels = set()
    for r in all_records:
        if get_product_dir(r) == product and r.get("openshiftVersion", "unknown") == ocp:
            historical_labels.add(get_script_label(r.get("testScript", "")))
    script_cols = ordered_script_labels(historical_labels)

    if not script_cols:
        script_cols = ["sanity"]

    col_hdr = " | ".join(f"**{c}**" for c in script_cols)
    sep = " | ".join(["---"] * (2 + len(script_cols)))
    lines += [f"| Config | {col_hdr} | Updated |", f"| {sep} |"]

    for variant in VARIANTS:
        cells = []
        latest_ts = ""
        has_any = False
        for label in script_cols:
            recs = cell_map.get((variant, label), [])
            if not recs:
                cells.append("—")
            else:
                has_any = True
                cells.append(linked_status_cell(recs[0]))
                ts = recs[0].get("timestamp", "")
                if ts > latest_ts:
                    latest_ts = ts
        updated = latest_ts[:10] if latest_ts else "—"
        # Link to variant dir (which now contains per-script subdirs)
        cells_str = " | ".join(cells)
        if has_any:
            lines.append(f"| [{variant}](./{variant}/) | {cells_str} | {updated} |")
        else:
            lines.append(f"| {variant} | {cells_str} | {updated} |")

    lines.append("")
    return "\n".join(lines)


# ── Version-level README (OCP summary for one operator version) ───────────────

def _version_cell(ocp_var_script_map, ocp, variant, script_cols):
    """Build a per-test-type breakdown cell for the version README.

    Returns (cell_markdown, latest_ts) where cell_markdown is a markdown link
    to the OCP README whose text is one line per test type with p/f/s counts.
    """
    type_lines = []
    latest_ts = ""
    for label in script_cols:
        recs = ocp_var_script_map.get((ocp, variant, label), [])
        if not recs:
            continue
        r = recs[0]
        icon = status_icon(r)
        passed  = r.get("testsPassed")
        failed  = (r.get("testsFailed") or 0) + (r.get("testsErrors") or 0)
        skipped = r.get("testsSkipped")
        if passed is not None or failed or skipped is not None:
            p = str(passed)  if passed  is not None else "?"
            s = str(skipped) if skipped is not None else "?"
            text = f"{label} {icon} {p}p/{failed}f/{s}s"
        else:
            text = f"{label} {icon}"
        type_lines.append(f"[{text}](./ocp-{ocp}/{variant}/{label}/)")
        ts = r.get("timestamp", "")
        if ts > latest_ts:
            latest_ts = ts

    if not type_lines:
        return "—", ""
    return "<br>".join(type_lines), latest_ts


def render_version_readme(ocp_var_script_map, product, version):
    """ocp_var_script_map: {(ocp, variant, script_label): [records newest-first]}"""
    lines = [f"# {product} / {version}", ""]

    # Component versions meta from first available record
    for recs in ocp_var_script_map.values():
        if recs:
            meta = build_meta_line(recs[0])
            if meta:
                lines += [meta, ""]
            break

    ocps = sorted({ocp for ocp, _, _ in ocp_var_script_map}, reverse=True)
    present_variants = [
        v for v in VARIANTS
        if any((ocp, v, sl) in ocp_var_script_map for ocp in ocps for sl in SCRIPT_LABEL_ORDER)
    ]
    script_cols = ordered_script_labels(
        {sl for _, _, sl in ocp_var_script_map}
    )

    col_hdr = " | ".join(f"**{v}**" for v in present_variants)
    sep = " | ".join(["---"] * (2 + len(present_variants)))
    lines += [f"| OCP | {col_hdr} | Updated |", f"| {sep} |"]

    for ocp in ocps:
        cells, latest_ts = [], ""
        for variant in present_variants:
            cell, ts = _version_cell(ocp_var_script_map, ocp, variant, script_cols)
            cells.append(cell)
            if ts > latest_ts:
                latest_ts = ts
        lines.append(f"| [{ocp}](./ocp-{ocp}/) | {' | '.join(cells)} | {latest_ts[:10]} |")

    lines.append("")
    return "\n".join(lines)


# ── Product-level README (version summary) ────────────────────────────────────

def render_product_readme(prod_groups, product):
    """prod_groups: {(version, ocp, variant): [records newest-first]}
    Records here are already collapsed across testScript (worst status).
    """
    lines = [f"# {product}", ""]

    versions = sorted(
        {version for version, _, _ in prod_groups},
        key=version_sort_key,
        reverse=True,
    )

    for version in versions:
        ocps = sorted(
            {ocp for v, ocp, _ in prod_groups if v == version},
            reverse=True,
        )
        present_variants = [
            var for var in VARIANTS
            if any((version, ocp, var) in prod_groups for ocp in ocps)
        ]

        col_hdr = " | ".join(f"**{v}**" for v in present_variants)
        sep = " | ".join(["---"] * (3 + len(present_variants)))

        lines += [
            f"## [{version}](./{version}/)",
            "",
            f"| OCP | {col_hdr} | ArgoCD | Updated |",
            f"| {sep} |",
        ]

        for ocp in ocps:
            cells, latest_ts, argocd_ver = [], "", ""
            for variant in present_variants:
                recs = prod_groups.get((version, ocp, variant), [])
                if not recs:
                    cells.append("—")
                else:
                    st = status_cell(recs[0])
                    cells.append(f"[{st}](./{version}/ocp-{ocp}/)")
                    ts = recs[0].get("timestamp", "")
                    if ts > latest_ts:
                        latest_ts = ts
                    if not argocd_ver:
                        argocd_ver = (recs[0].get("buildMetadata") or {}).get("argocd", "")
            lines.append(
                f"| [{ocp}](./{version}/ocp-{ocp}/) | {' | '.join(cells)} | {argocd_ver} | {latest_ts[:10]} |"
            )

        lines.append("")

    lines += ["---", "*Auto-generated by Konflux pipeline.*", ""]
    return "\n".join(lines)


# ── Top-level README ──────────────────────────────────────────────────────────

def render_top_readme(all_groups):
    lines = ["# Catalog Test Results", ""]

    # Nest: product -> version -> ocp -> variant -> [records] (collapsed across testScript)
    tree = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    for (product, version, ocp, variant), recs in all_groups.items():
        tree[product][version][ocp][variant] = recs

    for product in sorted(tree):
        lines.append(f"## [{product}](./{product}/)")
        lines.append("")
        versions = sorted(tree[product], key=version_sort_key, reverse=True)
        for version in versions[:3]:
            for ocp in sorted(tree[product][version], reverse=True):
                variant_data = tree[product][version][ocp]
                parts, latest_ts = [], ""
                for var in VARIANTS:
                    recs = variant_data.get(var, [])
                    if recs:
                        parts.append(f"{var}: {status_icon(recs[0])}")
                        ts = recs[0].get("timestamp", "")
                        if ts > latest_ts:
                            latest_ts = ts
                summary = " · ".join(parts)
                lines.append(
                    f"- **[{version} / OCP {ocp}](./{product}/{version}/ocp-{ocp}/)** "
                    f"— {summary} *(updated {latest_ts[:10]})*"
                )
        lines.append("")

    lines += ["---", "*Auto-generated by Konflux pipeline.*", ""]
    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def clean_generated_dirs(repo_dir):
    for dirname in set(PRODUCT_DIRS.values()):
        path = os.path.join(repo_dir, dirname)
        if os.path.isdir(path):
            shutil.rmtree(path)


def collapse_by_variant(script_variant_groups):
    """Collapse a {(variant, script_label): records} dict into {variant: worst_record}.

    Used for version/product/top READMEs which only need one status per variant.
    """
    result = defaultdict(list)
    for (variant, _label), recs in script_variant_groups.items():
        result[variant].extend(recs)
    # Sort by timestamp descending; prefer failed records to surface failures
    collapsed = {}
    for variant, recs in result.items():
        recs.sort(key=lambda r: (r.get("status") != "Succeeded", r.get("timestamp", "")), reverse=True)
        collapsed[variant] = recs
    return collapsed


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <repo-dir>")
        sys.exit(1)

    repo_dir = sys.argv[1]
    records = load_records(repo_dir)
    if not records:
        print("No records found in results.jsonl")
        return

    all_groups = group_records(records)

    # Wrap the destructive clean + full render in a try/except so that if
    # anything goes wrong after the directories are deleted (mid-render failure,
    # unexpected exception, etc.) we restore the repo to a known-good state via
    # git before propagating the error.  This prevents a corrupt partial state
    # from being committed and pushed.
    try:
        clean_generated_dirs(repo_dir)

        # all_groups key: (product, version, ocp, variant, script_label)
        by_product = defaultdict(dict)
        for (product, version, ocp, variant, script_label), recs in all_groups.items():
            by_product[product][(version, ocp, variant, script_label)] = recs

        total_groups = 0
        for product, prod_groups_full in by_product.items():

            # ── Leaf READMEs ──────────────────────────────────────────────────────
            for (version, ocp, variant, script_label), recs in prod_groups_full.items():
                leaf_dir = os.path.join(repo_dir, product, version, f"ocp-{ocp}", variant, script_label)
                os.makedirs(leaf_dir, exist_ok=True)
                with open(os.path.join(leaf_dir, "README.md"), "w") as f:
                    f.write(render_leaf_readme(recs, product, version, ocp, variant, script_label))
                total_groups += 1

            # ── OCP-level READMEs ─────────────────────────────────────────────────
            ocp_buckets = defaultdict(dict)  # (version, ocp) -> {(variant, script_label): records}
            for (version, ocp, variant, script_label), recs in prod_groups_full.items():
                ocp_buckets[(version, ocp)][(variant, script_label)] = recs
            for (version, ocp), cell_map in ocp_buckets.items():
                ocp_dir = os.path.join(repo_dir, product, version, f"ocp-{ocp}")
                os.makedirs(ocp_dir, exist_ok=True)
                with open(os.path.join(ocp_dir, "README.md"), "w") as f:
                    f.write(render_ocp_readme(cell_map, product, version, ocp, records))

            # ── Version-level READMEs ────────────────────────────────────────────
            ver_buckets = defaultdict(dict)  # version -> {(ocp, variant, script_label): records}
            for (version, ocp, variant, script_label), recs in prod_groups_full.items():
                ver_buckets[version][(ocp, variant, script_label)] = recs
            for version, ocp_var_script_map in ver_buckets.items():
                ver_dir = os.path.join(repo_dir, product, version)
                os.makedirs(ver_dir, exist_ok=True)
                with open(os.path.join(ver_dir, "README.md"), "w") as f:
                    f.write(render_version_readme(ocp_var_script_map, product, version))

            # ── Product-level README ─────────────────────────────────────────────
            # Collapse across script_label: worst status per (version, ocp, variant)
            prod_groups_collapsed = defaultdict(list)
            for (version, ocp, variant, script_label), recs in prod_groups_full.items():
                prod_groups_collapsed[(version, ocp, variant)].extend(recs)
            prod_groups_final = {}
            for key, recs in prod_groups_collapsed.items():
                recs.sort(key=lambda r: (r.get("status") != "Succeeded", r.get("timestamp", "")), reverse=True)
                prod_groups_final[key] = recs
            prod_dir = os.path.join(repo_dir, product)
            os.makedirs(prod_dir, exist_ok=True)
            with open(os.path.join(prod_dir, "README.md"), "w") as f:
                f.write(render_product_readme(prod_groups_final, product))

        # ── Top-level README ──────────────────────────────────────────────────
        # Build collapsed groups: (product, version, ocp, variant) -> worst-status records
        top_groups_raw = defaultdict(list)
        for (product, version, ocp, variant, script_label), recs in all_groups.items():
            top_groups_raw[(product, version, ocp, variant)].extend(recs)
        top_groups = {}
        for key, recs in top_groups_raw.items():
            recs.sort(key=lambda r: (r.get("status") != "Succeeded", r.get("timestamp", "")), reverse=True)
            top_groups[key] = recs

        with open(os.path.join(repo_dir, "README.md"), "w") as f:
            f.write(render_top_readme(top_groups))

    except Exception:
        # Rendering failed after the product directories were already deleted.
        # Restore the repo to its last committed state so nothing broken gets pushed.
        print("ERROR: rendering failed; restoring repo from git...", file=sys.stderr)
        try:
            subprocess.run(
                ["git", "checkout", "--", "."],
                cwd=repo_dir,
                check=True,
            )
            print("Repo restored via 'git checkout -- .'", file=sys.stderr)
        except subprocess.CalledProcessError as restore_err:
            print(f"WARNING: git restore also failed: {restore_err}", file=sys.stderr)
        raise

    print(f"Rendered {total_groups} result groups from {len(records)} records")


if __name__ == "__main__":
    main()
