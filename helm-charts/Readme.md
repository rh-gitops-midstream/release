# helm chart for openshift gitops and component

Generate helm chart for openshift-gitops operator from catalog

### pre-req
- kubectl-catalog cli installed https://github.com/anandf/kubectl-catalog
- catalog image reachable 
- pull-secrets if required


To generate template chart (doesn't contain CRD)
```sh
kubectl-catalog generate openshift-gitops-operator --channel gitops-1.22  --output-format helm --pull-secret ~/keys/pull-secret.txt --catalog quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.20 --chart-name openshift-gitops-operator --skip-crds
```

To generate CRD only chart for openshift-gitops
```sh
kubectl-catalog generate openshift-gitops-operator --channel gitops-1.22  --output-format helm --pull-secret ~/keys/pull-secret.txt --catalog quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.20 --chart-name openshift-gitops-operator --skip-templates 
```
