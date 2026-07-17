# Catalog Installation

> **Note:** This is a work in progress. Documentation will be enhanced further.

## Development/Stage Catalog Installation

Follow these steps to install the GitOps Operator using a development/stage catalog.

### 1. Create an `ImageDigestMirrorSet`

This mirror set ensures that OpenShift can pull images from development/stage repository.

```bash
oc apply -f https://raw.githubusercontent.com/rh-gitops-midstream/catalog/refs/heads/main/.tekton/images-mirror-set.yaml
```

### 2. Create a `CatalogSource`
Update the <catalog-image> with the correct development/stage catalog image.

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: gitops-test-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: <catalog-image>
  displayName: GitOps Test Catalog
  publisher: Red Hat
```

Available development/pre-release catalog images:
- OCP v4.14: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.14`
- OCP v4.15: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.15`
- OCP v4.16: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.16`
- OCP v4.17: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.17`
- OCP v4.18: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.18`
- OCP v4.19: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.19`
- OCP v4.20: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.20`
- OCP v4.21: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.21`
- OCP v4.22: `quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.22`

Apply using:
```bash
oc apply -f catalog-source.yaml
```

### 3. Verify Catalog Pod

Ensure the catalog pod is running in the openshift-marketplace namespace.

![Catalog Pod](assets/catalog-pod.png)

You can check with:

```bash
oc get pods -n openshift-marketplace
```

### 4. Install GitOps Operator

From the OperatorHub, select the GitOps Test Catalog as the source and install the GitOps Operator.

![Operator Installation from Dev/Stage Catalog](assets/operator-install.png)
