# Catalog Installation

TODO: Improve the documentation

## Development Catalog Installation

1. Create `ImageContentSourcePolicy` policy to pull from quay

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: gitops-testing-icsp
spec:
  repositoryDigestMirrors:
    - source: registry.redhat.io/openshift-gitops-1/gitops-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-backend
    - source: registry.redhat.io/openshift-gitops-1/console-plugin-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-console-plugin
    - source: registry.redhat.io/openshift-gitops-1/dex-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/dex
    - source: registry.redhat.io/openshift-gitops-1/must-gather-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-must-gather
    - source: registry.redhat.io/openshift-gitops-1/argocd-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argo-cd
    - source: registry.redhat.io/openshift-gitops-1/argo-rollouts-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argo-rollouts
    - source: registry.redhat.io/openshift-gitops-1/gitops-operator-bundle
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle
    - source: registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator
    - source: registry.redhat.io/openshift-gitops-1/argocd-extensions-rhel8
      mirrors:
        - quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-extension-installer
```

2. Create `CatalogSource` 

Update catalog image before applying

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: gitops-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: <catalog image>
  displayName: GitOps Stage Catalog
  publisher: Red Hat
```

3. Ensure catalog pod is running in `openshift-marketplace` namespace

![Catalog Pod](assets/catalog-pod.png)

4. Install GitOps Operator from OperatorHub

Ensure you install Operator from `GitOps Stage Catalog` source.

![Operator Installation from Dev Catalog](assets/operator-install.png)