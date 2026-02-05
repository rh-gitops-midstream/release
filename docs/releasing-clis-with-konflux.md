# How to Release OpenShift GitOps CLIs/Binaries with Konflux?

> **Note:** This is a work in progress. Documentation will be enhanced further.

This document provides the workflow for releasing binary artifacts for OpenShift GitOps via Konflux. These artifacts are ultimately hosted at the [Red Hat Developer Portal Content Gateway](https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/).


## Step 0: GitLab Configuration

### 0.1 Configure Product Version

If not already present, create a new product version file for the version you are planning to release.

```yaml
---
- type: product_version
  action: create
  metadata:
    productName: "Cloud: OpenShift GitOps"
    productCode: "openshift-gitops"
    versionName: "<new-version>"
    ga: true
    termsAndConditions: "Anonymous Download" # or "Basic"
    hidden: false
    invisible: false
    releaseDate: "<release-date>"
```

#### References

- `data/external/developer-portal/product-versions/rh-openshift-gitops/1.19.0.yaml` (GitLab)
- Internal Konflux documentation:
https://konflux.pages.redhat.com/docs/users/releasing/releasing-artifacts-to-cdn.html#developer-portal-aka-content-gateway-wiki

### 0.2 Create or Update RPA

Create or update the ReleasePlanAdmission (RPA) for your version at:

```
config/stone-prd-rh01.pg1f.p1/product/ReleasePlanAdmission/rh-openshift-gitops/
```

Ensure your binary details are included under `mapping.components`.

```yaml
mapping:
  components:
    - name: <release-component>-cli-1-19
      files:
        - filename: <release-component>-linux-amd64.tar.gz
          source: /releases/<release-component>-linux-amd64.tar.gz
          arch: x86_64
          os: linux
        - filename: <release-component>-linux-ppc64le.tar.gz
          source: /releases/<release-component>-linux-ppc64le.tar.gz
          arch: ppc64le
          os: linux
```

#### References
- Existing RPA:
`config/stone-prd-rh01.pg1f.p1/product/ReleasePlanAdmission/rh-openshift-gitops/gitops-clis-1-19-prod.yaml`
- Internal documentation:
https://konflux.pages.redhat.com/docs/users/releasing/releasing-artifacts-to-cdn.html#custom-resource-setup

### 0.3 Submit Merge Request

1. Commit your changes to a new branch.
2. Open a Merge Request (MR) for review.

> [!NOTE]  
> If your MR includes changes under the `product-version/` directory, approval from Release Engineering (rel-eng) is required. Create a support request in the `#konflux-users` Slack channel requesting a review.

## Step 1: Perform the Release

Binary artifacts are released by applying a Release CR on the Konflux cluster.

Release CRs are located under:

```
releases/production/<version>/
```

Each Release CR contains:
- Snapshot details (component images containing binaries)
- Artifact details

**Example:** https://github.com/rh-gitops-midstream/release/blob/release-1.19/releases/production/1.19.0/cli-release.yaml

### Pre-Release Checklist
Before starting the release, ensure that:
- You have checked out the correct **release-\*** branch.
- You are logged into the Konflux cluster with sufficient permissions.

### Apply the Production Release CR

Trigger the production release by applying the Release CR:
```bash
oc create -f releases/production/1.19.0/cli-release.yaml
```

> [!TIP]
> **Testing in "Staging":** Konflux doesn't have a dedicated staging environment for artifacts release pipeline. To test a new artifact, use a pre-release version (e.g., `1.19.0-pre-release`). Create a temporary RPA and Release object that targets `only` the new component to prevent conflicts with existing artifacts.

### Monitor the Release

You can monitor the release via the Konflux UI:
- Navigate to: **Applications → gitops-x.y → Releases**
- Namespace: `rh-openshift-gitops-tenant`
- Locate your release under the **Releases** section

To view execution details:
- Use the **ManagePipeline** column
- Follow the links to the managed PipelineRun

### Errata Details (Post Release)

Currently, errata is not created automatically when binary artifacts are released.

### Post-Release Validation

Download and verify the released binaries from:

https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/openshift-gitops/

### Troubleshooting

TODO