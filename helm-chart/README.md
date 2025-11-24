# Helm Chart Publishing Scripts

This directory contains scripts for publishing RedHat-specific Argo CD Agent Helm charts. These scripts update the argocd-agent helm chart with RedHat-specific configurations and prepare them for distribution.

## Overview

The scripts in this directory automate the process of:
- Extracting the Argo CD Agent helm chart from the submodule
- Applying RedHat-specific configurations
- Updating image repositories and tags
- Generating documentation
- (For stage releases) Packaging and pushing to OCI registry

## Prerequisites

### Common Prerequisites (Both Scripts)

- **Git submodule initialized**: The `sources/argocd-agent` submodule must be initialized
- **yq**: Must be installed and available at `bin/yq` in the repository root
- **helm-docs**: Must be installed and available in PATH. [download binary](https://github.com/norwoodj/helm-docs/releases).
- **config.yaml**: Must exist in the repository root with proper source configuration
- **Git repository**: Should be run from the `main` branch or a tagged commit (warning shown if not)

### Additional Prerequisites for `publish-stage.sh`

- **helm**: Must be installed and available in PATH
  ```bash
  # Installation: https://helm.sh/docs/intro/install/
  ```

## Scripts

### `publish.sh`

**Purpose**: Updates the argocd-agent helm chart with RedHat-specific configurations for production releases.

**What it does**:
1. Validates the image tag format
2. Reads commit and ref from `config.yaml`
3. Initializes and updates the `sources/argocd-agent` submodule
4. Copies the helm chart to an output directory named `{commit}-{ref}`
5. Updates `Chart.yaml` with RedHat-specific metadata
6. Updates `values.yaml` with production image repository:
   - Image repository: `registry.redhat.io/openshift-gitops-1/argocd-agent-rhel8`
   - Image tag: Provided as argument, should be similar to what is present on the catalog. e.g. v1.18.1, v1.18.1-2
7. Generates helm chart documentation using `helm-docs`

**Usage**:
```bash
./helm-chart/publish.sh <tag>
```

**Arguments**:
- `tag` (required): The image tag in format `v<major>.<minor>.<patch>[-<build>]`
  - Examples: `v1.18.1`, `v1.18.1-2`

**Example**:
```bash
./helm-chart/publish.sh v1.18.1-2
```

**Output**:
- Creates a directory: `helm-chart/{commit}-{ref}/`
- Contains the updated helm chart with RedHat configurations
- Includes generated `README.md` documentation

**Image Repository**:
- Production: `registry.redhat.io/openshift-gitops-1/argocd-agent-rhel8`

---

### `publish-stage.sh`

**Purpose**: Updates the argocd-agent helm chart with RedHat-specific configurations for stage releases and publishes to OCI registry.

**What it does**:
1. Reads commit and ref from `config.yaml`
2. Initializes and updates the `sources/argocd-agent` submodule
3. Copies the helm chart to an output directory named `{commit}-{ref}-stage`
4. Updates `Chart.yaml` with RedHat-specific metadata
5. Updates `values.yaml` with stage image repository:
   - Image repository: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-agent-rhel8`
   - Image tag: Provided as argument
6. Generates helm chart documentation using `helm-docs`
7. Packages the helm chart using `helm package`
8. Pushes the packaged chart to OCI registry (default: `oci://quay.io/anandrkskd/argocd-agent`, can be overridden with `HELM_OCI_REGISTRY` environment variable)

**Usage**:
```bash
./helm-chart/publish-stage.sh <tag>
```

**Arguments**:
- `tag` (required): The image tag (e.g., `v1.18.1-2`)

**Environment Variables**:
- `HELM_OCI_REGISTRY` (optional): Override the default OCI registry. If not set, defaults to `oci://quay.io/anandrkskd/argocd-agent`

**Example**:
```bash
# Using default OCI registry
./helm-chart/publish-stage.sh v1.18.1-2

# Using custom OCI registry
HELM_OCI_REGISTRY="oci://quay.io/my-org/my-charts" ./helm-chart/publish-stage.sh v1.18.1-2
```

**Output**:
- Creates a directory: `helm-chart/{commit}-{ref}-stage/`
- Contains the updated helm chart with RedHat configurations
- Includes generated `README.md` documentation
- Creates a packaged chart: `{chart-name}-{version}.tgz`
- Pushes the chart to OCI registry

**Image Repository**:
- Stage: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-agent-rhel8`

**OCI Registry**:
- Default: `oci://quay.io/anandrkskd/argocd-agent`
- Can be overridden using `HELM_OCI_REGISTRY` environment variable

---

## Key Differences

| Feature | `publish.sh` | `publish-stage.sh` |
|---------|--------------|-------------------|
| **Purpose** | Production release | Stage release |
| **Image Repository** | `registry.redhat.io/openshift-gitops-1/argocd-agent-rhel8` | `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-agent-rhel8` |
| **Output Directory** | `{commit}-{ref}` | `{commit}-{ref}-stage` |
| **Tag Validation** | Strict format validation | No strict validation |
| **Packaging** | No | Yes (creates `.tgz` file) |
| **OCI Push** | No | Yes (pushes to OCI registry) |
| **Helm Required** | No | Yes |

## Workflow

### Production Release (`publish.sh`)

```bash
# 1. Ensure you're on main branch or a tagged commit
git checkout main
# or
git checkout <tagged-branch>

# 2. Run the script with the image tag
./helm-chart/publish.sh v1.18.1-2

# 3. The updated chart is available in:
# helm-chart/{commit}-{ref}/
```

### Stage Release (`publish-stage.sh`)

```bash
# 1. Ensure you're on main branch or a tagged commit
git checkout main
# or
git checkout <tagged-branch>

# 2. Ensure you're authenticated to the OCI registry
# (helm will use your configured credentials)

# 3. Run the script with the image tag
# Using default OCI registry
./helm-chart/publish-stage.sh v1.18.1-2

# Or use a custom OCI registry
HELM_OCI_REGISTRY="oci://quay.io/my-org/my-charts" ./helm-chart/publish-stage.sh v1.18.1-2

# 4. The chart is packaged and pushed to the OCI registry
# (default: oci://quay.io/anandrkskd/argocd-agent)
```

## Configuration

Both scripts read configuration from `config.yaml` in the repository root. They extract:
- `commit`: The commit hash for `sources/argocd-agent`
- `ref`: The reference (branch/tag) for `sources/argocd-agent`

Example `config.yaml` structure:
```yaml
sources:
  - path: sources/argocd-agent
    commit: abc123def456
    ref: v1.18.1
```

## Output Structure

After running either script, the output directory contains:
```
{commit}-{ref}[-stage]/
├── Chart.yaml          # Updated with RedHat metadata
├── values.yaml          # Updated with RedHat image repository and tag
├── README.md            # Auto-generated documentation
├── templates/           # Helm chart templates
└── ...                  # Other chart files
```

For `publish-stage.sh`, an additional `.tgz` file is created:
```
{chart-name}-{version}.tgz  # Packaged helm chart
```

## Troubleshooting

### Common Issues

1. **"yq not found"**
   - Ensure `yq` is installed at `bin/yq` in the repository root
   - Check file permissions

2. **"helm-docs is not installed"**
   - Install: `go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest`
   - Ensure `$GOPATH/bin` or `$GOBIN` is in your PATH

3. **"Failed to initialize argocd-agent submodule"**
   - Run: `git submodule update --init --recursive sources/argocd-agent`
   - Check submodule configuration in `.gitmodules`

4. **"config.yaml not found"**
   - Ensure `config.yaml` exists in the repository root
   - Verify the file contains the required `sources` section

5. **"Failed to push helm chart to OCI registry"** (publish-stage.sh only)
   - Ensure you're authenticated to the OCI registry
   - Check registry permissions
   - Verify the registry URL is correct

6. **"Invalid tag format"** (publish.sh only)
   - Tag must match: `v<major>.<minor>.<patch>[-<build>]`
   - Examples: `v1.18.1`, `v1.18.1-2`
   - Note: `publish-stage.sh` does not validate tag format

## Notes

- ⚠️ **Important**: These scripts should be run from a tagged branch or from the `main` branch
- The scripts create copies of the helm chart; they do not modify the original submodule
- All file operations preserve attributes and permissions using `cp -a`
- The scripts use colored output for better readability (INFO=green, WARN=yellow, ERROR=red)

