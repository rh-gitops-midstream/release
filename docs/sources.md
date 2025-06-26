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