# Konflux Component Guide

This document outlines the steps to add a new component to the Konflux CI system. It covers both the internal GitLab configuration and GitHub repository updates required for building the new components.

### TODO: Improve doc and automate the new component setup

## Adding a New Component

The `<new-component>` name should align with the it's downstream image name.  
Example:
For downstream image `argocd-rhel8`, the component name is `argocd`.  
For downstream image `gitops-rhel8-operator`, the component name is `gitops-operator`.  

### Step 1: Internal GitLab Configuration

#### 1.1 Add `ImageRepository`

- Path: `tenants-config/cluster/stone-prd-rh01/tenants/rh-openshift-gitops-tenant/image-repository.yaml`
- Copy an existing ImageRepository object and modify:
```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ImageRepository
metadata:
  name: <new-component-image>-quay-image-repository
spec:
  image:
    name: rh-openshift-gitops-tenant/<new-component-image>
    visibility: public
```

>  Note: `<new-component-image>` must match the downstream container image name.

#### 1.2 Add `Component`

- Path:
`tenants-config/cluster/stone-prd-rh01/tenants/rh-openshift-gitops-tenant/gitops-main.yaml`
- Copy an existing `Component` and update:
```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: <new-component>-main
spec:
  application: gitops-main
  componentName: <new-component>-main
  source:
    git:
      url: https://github.com/rh-gitops-midstream/release.git
      revision: main
      dockerfileUrl: containers/<new-component>/Dockerfile
  containerImage: quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/<new-component-image>
```

#### 1.3 Build and Test

- Run the manifest generator:
```bash
./tenants-config/build-manifests.sh
```
- Run tests:
```bash
tox
```

#### 1.4 Submit Changes

- Commit your changes.
- Create a Merge Request (MR) for review.

### Step 2: GitHub Repository Updates

#### 2.1 Add Source Code

If not already present, add source under the `sources/` directory. Refer [Adding a New Source](sources-guide.md#adding-a-new-source) guide.

#### 2.2 Add Downstream Dockerfile

- Place Dockerfile in `containers/<new-component>/`
- Update the paths in the Dockerfile to reference the source code from the `sources/<new-component>/` directory. Refer to existing component Dockerfiles for guidance.
- Build the container locally using `make container name=<new-component>` to verify that the Dockerfile works as expected.

#### 2.4 Configure CI Pipelines

- Path: `.tekton/`
- Rename to match your new component:
    - `<new-component>-pull-request.yaml`
    - `<new-component>-push.yaml`
- Update the contents with the `<new-component>` name and relevant paths:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  annotations:
    pipelinesascode.tekton.dev/on-cel-expression: >
      event == "push" && target_branch == "main" && 
      ( "sources/<new-component-source>".pathChanged() || 
        "containers/<new-component>/***".pathChanged() || 
        ".tekton/<new-component>-push.yaml".pathChanged() || 
        ".tekton/build-multi-platform-image.yaml".pathChanged() || 
        ".tekton/tasks/***".pathChanged() )
  labels:
    appstudio.openshift.io/component: <new-component>-main
  name: <new-component>-main-on-push
spec:
  params:
    - name: output-image
      value: quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/<new-image>:{{revision}}
    - name: dockerfile
      value: containers/<new-component>/Dockerfile
    - name: prefetch-input
      value: <path-to-gomod-or-yarn.lock-or-rpm-lock>
    - name: git-metadata-directories
      value:
        - <source-directory>
  taskRunTemplate:
    serviceAccountName: build-pipeline-<new-component>-main
```

See PRs [#91](https://github.com/rh-gitops-midstream/release/pull/91) and [#182](https://github.com/rh-gitops-midstream/release/pull/182) for reference. 

Note: If the component requires RPMs, they must be prefetched. Refer to the `prefetch/rpms/README.md` file for more details.

#### 2.5 Submit PR

- Commit your changes to a new branch.
- Open a Pull Request for review.
