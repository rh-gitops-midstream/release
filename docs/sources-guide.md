# Source Repositories Guide

This document describes the `sources` section in the release `config.yaml`, which lists Git repositories used to build the GitOps Operator and related components.

## Field Reference

Each `sources` entry in `config.yaml` includes the following fields:

| Field   | Description |
|---------|-------------|
| `path`  | Local path where the repository will be cloned as a submodule. Must be under `sources` directory. |
| `url`   | Git repository URL (HTTPS). |
| `commit` | Specific commit hash to checkout. |
| `ref`   | Git branch or tag used **only by CI** for generating release labels. Not used for checkout. |

> [!WARNING] 
> The `commit` field is always used for checkout. `ref` is purely metadata for CI.

## Updating a Source

1. Edit the entry in `config.yaml` with the new `commit` and `ref`:

```yaml
sources:
  ...
  - path: ...
    url: ...
    ref: <new tag or branch>
    commit: <new commit hash>
```

2. Sync & validate submodules:

```bash
make sources
```

## Refreshing Sources Automatically

Use the updater script when you want to refresh the `sources` section directly from GitHub:

```bash
make update-sources
```

The script applies these rules:

- The current `ref` value is classified using the exact upstream ref name.
- If that exact ref is a branch, it updates `commit` to the current branch tip.
- It skips the mainline branches `main` and `master`.
- If that exact ref is a tag and it looks like a release version, it searches for the latest available z-stream tag in the same major/minor stream and updates both `ref` and `commit`.
- If a tag is not semver-like or there is no newer z-stream tag, it keeps the current `ref` and only ensures the tag commit is correct.

## Adding a New Source

1. Add a new entry to `config.yaml`:

```yaml
sources:
  ...
  - path: sources/<repo>
    url: <repo-url>
    ref: <tag or branch>
    commit: <commit hash>
```

> [!IMPORTANT]  
The submodule `path` must always be under the `sources/` directory.

2. Initialize, sync & validate submodules

```bash
make sources
```