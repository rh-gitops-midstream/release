# Generating a Release Candidate

Generate an RC build for OpenShift GitOps using the **Build Release Candidate** workflow.

## Quick Start

1. Ensure sources in `config.yaml` are up to date (see [Updating Sources](#updating-sources) below)
2. Go to **Actions** > **Build Release Candidate** > **Run workflow**
3. Set the inputs:

| Input | Description |
|-------|-------------|
| `TARGET_BRANCH` | Branch to build the RC for (e.g. `release-1.22`, `main`) |
| `START_FROM` | Which phase to start from (default: `full-build`) |

4. The workflow runs three phases sequentially — Operator Build, Bundle Build, and Catalog Build. The final catalog PR is labeled `release-candidate`.

### Output

The RC pipeline produces container images at each phase, built by Konflux and pushed to `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/`:

| Phase | Artifacts |
|-------|-----------|
| Operator Build | Component images (argocd, gitops-operator, dex, console-plugin, etc.) |
| Bundle Build | Operator bundle image (`gitops-operator-bundle`) |
| Catalog Build | Catalog image in the [catalog repository](https://github.com/rh-gitops-midstream/catalog) |

The final deliverable is the **catalog PR** in `rh-gitops-midstream/catalog`. Once Konflux builds the catalog image from that PR, the RC is ready for testing. On release, images are published to `registry.redhat.io/openshift-gitops-1/`.

### `START_FROM` options

Use `START_FROM` to restart from a specific phase when earlier phases already completed:

| Option | Starts from | Use when |
|--------|-------------|----------|
| `full-build` | Operator Build | Starting a fresh RC build from scratch |
| `bundle-build` | Bundle Build | Operator images are already built (e.g. operator phase succeeded but bundle phase failed) |
| `catalog-build` | Catalog Build | Operator and bundle images are built (e.g. only the catalog PR needs to be regenerated) |

---

## Build Phases

Each phase creates a PR, waits for Konflux CI, merges, and waits for post-merge Konflux builds before proceeding to the next phase.

### Operator Build

- Increments the build number in the `BUILD` file (e.g. `v1.22.0-34` to `v1.22.0-35`)
- Creates and merges a PR with the updated `BUILD` file
- Waits for Konflux to build all operator component images from the merge commit

### Bundle Build

- Runs `make bundle` to update the operator bundle manifests with the latest Konflux-built image SHAs (fetched via `skopeo`)
- Creates and merges a PR with the updated bundle files
- Waits for Konflux to build the operator bundle image from the merge commit

### Catalog Build

- Runs `make catalog` to generate the OLM catalog in the [catalog repository](https://github.com/rh-gitops-midstream/catalog)
- Creates a PR in the catalog repository
- On **manual dispatch**: the catalog PR is labeled `release-candidate`
- On **scheduled (nightly) runs**: the catalog PR is labeled `nightly` and `do-not-merge`

## Updating Sources

Before triggering an RC build, ensure the source repositories in `config.yaml` are up to date.

### Via workflow

Run the **Update Sources** workflow from the Actions tab with `workflow_dispatch`:
- Set `TARGET_BRANCH` to the branch you want to update (e.g. `release-1.22`)
- The workflow runs `make update-sources`, which refreshes source commits based on each source's `ref` field
- A PR is created with the changes for review and manual merge

> [!NOTE]
> On scheduled runs, the workflow automatically monitors CI and merges the PR. On manual dispatch, monitoring and merge are skipped so you can review the changes before merging.

### Manually

1. Edit `config.yaml` — update the `ref` and `commit` fields for the sources you want to change:

   ```yaml
   sources:
     - path: sources/argo-cd
       url: https://github.com/argoproj/argo-cd.git
       ref: v3.5.3        # new tag
       commit: abc123...   # commit for the new tag
       auto-update: true
   ```

2. Sync and validate submodules:

   ```bash
   make sources
   ```

### The `auto-update` field

Each source entry has an `auto-update` field that controls whether `make update-sources` will refresh it:

- `auto-update: true` — the source is updated automatically. For tags, this means z-stream upgrades within the same minor version. For branches, it updates to the latest commit.
- `auto-update: false` — the source is skipped by `make update-sources` and must be updated manually.

Y-stream upgrades (e.g. `v3.5.x` to `v3.6.x`) always require a manual update regardless of this setting.

## Nightly Builds

The workflow runs on a schedule (nightly) for multiple branches. Nightly builds follow the same three phases but the catalog PR is labeled `nightly` and `do-not-merge` instead of `release-candidate`. Nightly catalog PRs exist only to trigger Konflux catalog builds and should not be merged.

Stale nightly catalog PRs are cleaned up by a separate scheduled workflow in the catalog repository.
