# Project Structure

This document describes the layout of the `rh-gitops-midstream/release` repository, which contains the configurations, Dockerfiles, and automation used to build and release Red Hat OpenShift GitOps artifacts via Konflux CI.

## Top-Level Overview

```
release/
├── .tekton/          # Konflux/Tekton CI pipeline definitions
├── BUILD             # Current build version (base-version-build-number)
├── Makefile          # Developer workflow targets
├── README.md         # Repository overview and documentation index
├── config.yaml       # Central release metadata and source/image configuration
├── clis/             # Dockerfiles for CLI binary artifacts
├── containers/       # Dockerfiles for container image artifacts
├── docs/             # Project documentation
├── hack/             # Helper scripts used by Makefile targets
├── helm-charts/      # Helm chart sources
├── prefetch/         # Dependency lock files for Konflux hermetic builds
├── rpms/             # RPM spec files for MicroShift GitOps
└── sources/          # Git submodules for upstream source repositories
```

## Key Files

| File | Description |
|------|-------------|
| `config.yaml` | Central configuration file. Defines the release metadata (`release`), upstream source repositories (`sources`), external registry images (`externalImages`), and Konflux-built images (`konfluxImages`). See [sources-guide.md](sources-guide.md) for details on managing the `sources` section. |
| `BUILD` | Tracks the current build version in `<base-version>-<build-number>` format (e.g. `v1.19.1-3`). Managed with `make update-build`. |
| `Makefile` | Provides developer workflow targets. Run `make help` or read the file directly for the full list. Key targets: `sources`, `update-sources`, `bundle`, `container`, `cli`, `catalog`. |
| `.gitmodules` | Defines the Git submodule paths and URLs for everything under `sources/`. |
| `renovate.json` | Renovate bot configuration for automated dependency update PRs. |

## Directories

### `.tekton/`

Contains Tekton `PipelineRun` manifests consumed by Konflux/Pipelines as Code. Each component has two files:

- `<component>-pull-request.yaml` — triggered on pull requests
- `<component>-push.yaml` — triggered on pushes to `main`

Shared pipeline templates used by all components live in `.tekton/tasks/` and `.tekton/build-multi-platform-image.yaml`.

### `clis/`

Contains one sub-directory per CLI/binary artifact. Each sub-directory holds a `Dockerfile` that compiles the binary from source and packages it into tarballs under `/releases/` for distribution via the Red Hat Content Gateway.

```
clis/
├── argocd/
├── argocd-agentctl/
└── kubectl-argo-rollouts/
```

For instructions on adding a new CLI, see [new-cli-onboarding-guide.md](new-cli-onboarding-guide.md).

### `containers/`

Contains one sub-directory per container image artifact. Each sub-directory holds a `Dockerfile` that produces a RHEL-based downstream image from the corresponding upstream source.

```
containers/
├── argo-rollouts/
├── argocd/
├── argocd-agent/
├── argocd-extensions/
├── argocd-image-updater/
├── console-plugin/
├── dex/
├── gitops/
├── gitops-operator/
├── gitops-operator-bundle/
└── must-gather/
```

For instructions on adding a new container component, see [konflux-component-guide.md](konflux-component-guide.md).

### `docs/`

Project documentation. All guides are linked from [README.md](../README.md).

| File | Description |
|------|-------------|
| `project-structure.md` | This file. Overview of the repository layout. |
| `sources-guide.md` | How to manage upstream source entries in `config.yaml`. |
| `konflux-component-guide.md` | How to add a new container image component to Konflux. |
| `new-cli-onboarding-guide.md` | How to onboard a new CLI binary component to Konflux. |
| `releasing-with-konflux.md` | How to perform a full component and catalog release with Konflux. |
| `releasing-clis-with-konflux.md` | How to release CLI/binary artifacts via Konflux. |
| `prepare-for-a-zstream-release.md` | Pre-release checklist and steps for a Z-stream release. |
| `catalog-installation.md` | How to install the GitOps Operator from a dev/stage catalog. |

### `hack/`

Shell and Python helper scripts called by `Makefile` targets. Not intended to be run directly in most cases.

| Script | Description |
|--------|-------------|
| `deps.sh` | Installs required tooling (e.g. `yq`) into `./bin/`. |
| `sync-sources.sh` | Initialises and syncs Git submodules to the commits specified in `config.yaml`. |
| `verify-sources.sh` | Validates that each submodule is checked out at the correct commit. |
| `update-sources.sh` | Queries GitHub to refresh `ref`/`commit` values in `config.yaml`. |
| `setup-release.py` | Scaffolds release YAML files for a new version. |
| `generate-catalog.py` | Generates the OLM operator catalog from current image data. |
| `generate-agent-helm-chart.py` | Generates the ArgoCD Agent Helm chart. |
| `update-tekton-task-bundles.sh` | Updates pinned Tekton task bundle digests in `.tekton/` files. |

### `helm-charts/`

Contains Helm chart source templates. Currently holds the ArgoCD Agent chart under `helm-charts/redhat-argocd-agent/`. The chart is generated from templates via `make agent-helm-chart` and packaged with `make agent-helm-chart-package`.

### `prefetch/`

Contains dependency lock files used by Konflux's hermetic build system to pre-fetch dependencies before the build sandbox loses network access.

```
prefetch/
├── rpms/    # RPM lock files (rpm-lockfile-prototype format)
└── yarn/    # Yarn lock files for Node.js components
```

### `rpms/`

Contains RPM spec files for packages that are not built as container images.

```
rpms/
└── microshift-gitops/    # RPM spec for the MicroShift GitOps plugin
```

### `sources/`

Git submodules for each upstream repository referenced in the `sources` section of `config.yaml`. The submodules are managed with:

```bash
make sources          # sync & validate
make update-sources   # refresh to latest commits/tags
```

See [sources-guide.md](sources-guide.md) for the full field reference and workflow.
