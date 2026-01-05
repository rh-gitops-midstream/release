# New CLI Onboarding Guide

This document describes the end-to-end process for onboarding a new CLI/binary component into the **Konflux CI system**. The workflow spans internal GitLab tenant configuration and updates to the GitHub midstream repository.

> **TODO**
>
> - Improve this documentation further  
> - Automate the new component onboarding process where possible

## Adding a New Component

The `<new-component>` name **must match the downstream binary name**.

### Examples

- Downstream binary: `argocd` → Component name: `argocd`
- Downstream binary: `argocd-agentctl` → Component name: `argocd-agentctl`

## Step 1: Internal GitLab Configuration

### 1.1 Add `ImageRepository`

**Path**: `tenants-config/cluster/stone-prd-rh01/tenants/rh-openshift-gitops-tenant/image-repository.yaml`

Copy an existing `ImageRepository` entry and update it as shown below:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ImageRepository
metadata:
  name: <new-component>-cli-quay-image-repository
spec:
  image:
    name: rh-openshift-gitops-tenant/<new-component>-cli
    visibility: public
```

> [!IMPORTANT]  
> <new-component> must exactly match the downstream binary name.

### 1.2 Add `Component`

**Path**: `tenants-config/cluster/stone-prd-rh01/tenants/rh-openshift-gitops-tenant/gitops-main.yaml`

Copy an existing Component and update the fields accordingly:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: <new-component>-cli-main
spec:
  application: gitops-main
  componentName: <new-component>-cli-main
  source:
    git:
      url: https://github.com/rh-gitops-midstream/release.git
      revision: main
      dockerfileUrl: clis/<new-component>/Dockerfile
  containerImage: quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/<new-component>-cli
```

> [!TIP]  
> Refer to GitLab MRs `!11441` and `!11582` for real examples.

### 1.3 Build and Test

Generate manifests:

```bash
./tenants-config/build-single.sh rh-openshift-gitops-tenant
```
Run tests:
```bash
tox
```

### 1.4 Submit Changes

1. Commit your changes.
2. Open a Merge Request (MR) for review.

### Step 2: GitHub Repository Updates

#### 2.1 Add Source Code

If not already present, add source under the `sources/` directory. Refer [Adding a New Source](sources-guide.md#adding-a-new-source) guide.

#### 2.2 Add Downstream Dockerfile

In Konflux, CLI binaries are built inside a container and stored under the `/releases` directory in **tarball format** using the following naming convention:

```
<component-name>-<os>-<arch>.tar.gz
```

**Examples:**
- `argocd-linux-amd64.tar.gz`
- `argocd-agentctl-darwin-arm64.tar.gz`

**Steps**
1. Create a Dockerfile at `clis/<new-component>/Dockerfile`
2. Ensure the Dockerfile references source code from: `sources/<source-directory>/`
3. Build and validate locally: `make container name=<new-component>`

> [!TIP]
> Refer to existing CLI Dockerfiles for guidance and best practices.

#### 2.3 Configure CI Pipelines

- Path: `.tekton/`

Steps
1. Copy the following pipeline files:
    - `argocd-cli-pull-request.yaml`
    - `argocd-cli-push.yaml`
2. Rename to match your new component:
    - `<new-component>-pull-request.yaml`
    - `<new-component>-push.yaml`
3. Update the contents with the `<new-component>` name and relevant paths:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  annotations:
    pipelinesascode.tekton.dev/on-cel-expression: >
      event == "push" && target_branch == "main" &&
      ( "sources/<source-directory>".pathChanged() ||
        "clis/<new-component>/***".pathChanged() ||
        ".tekton/<new-component>-push.yaml".pathChanged() ||
        ".tekton/build-multi-platform-image.yaml".pathChanged() )
  labels:
    appstudio.openshift.io/component: <new-component>-cli-main
  name: <new-component>-cli-main-on-push
spec:
  params:
    - name: output-image
      value: quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/<new-component>-cli:{{revision}}
    - name: dockerfile
      value: clis/<new-component>/Dockerfile
    - name: prefetch-input
      value: <path-to-gomod-or-yarn.lock-or-rpm-lock>
    - name: git-metadata-directories
      value:
        - <source-directory>
  taskRunTemplate:
    serviceAccountName: build-pipeline-<new-component>-cli-main
```

> [!TIP]  
> See PRs [#391](https://github.com/rh-gitops-midstream/release/pull/391) and [#224](https://github.com/rh-gitops-midstream/release/pull/224) for reference. 

> [!NOTE]  
> If the component requires RPMs, they must be prefetched. Refer to the `prefetch/rpms/README.md` file for more details. 

#### 2.4 Submit PR 

1. Commit your changes to a new branch. 
2. Open a Pull Request for review.