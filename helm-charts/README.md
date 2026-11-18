# Helm charts for OpenShift GitOps

## Charts

| Chart | Updated by automation | Contents |
|-------|-----------------------|----------|
| `openshift-gitops-operator` | yes | Operator templates, `values.yaml`, and all CRDs in `crds/` |
| `openshift-gitops-operator-crds` | **no** (legacy) | CRDs only. Frozen at the last update; no longer regenerated |

The operator chart is generated from the operator **bundle image** with
[`kubectl-catalog`](https://github.com/anandf/kubectl-catalog). Do not edit its
`crds/`, `templates/` or `values.yaml` by hand; the next run overwrites them.

> Helm installs files in `crds/` on first install only. It never upgrades or
> deletes them on `helm upgrade`, so CRD changes must be applied separately
> (for example `kubectl apply -f crds/`) on existing clusters.

## How it is updated

`hack/update-helm-chart.sh <bundle-image>` regenerates `openshift-gitops-operator`.
CI runs it from `.github/workflows/update-helm-charts.yaml`, which is dispatched by
`build-release-candidate.yaml` for `main` and `release-1.23+`, and opens a PR.

The script:

1. Checks `kubectl-catalog` has the flags it needs, then reads `release.version` and
   the channel (first entry of `release.olm.channel` other than `latest`) from
   `config.yaml`. Nothing is touched until these checks pass.
2. Runs `kubectl-catalog generate --bundle <image> --output-format helm
   --env ENABLE_CONVERSION_WEBHOOK=false` into a temp directory.
3. Patches the generated output:
   - removes the GitopsService CRD (`gitopsservices*.yaml`) and its line in `NOTES.txt`
   - in `argocds.argoproj.io.yaml`, removes `.spec.conversion` and the `v1alpha1` version
4. Stages a copy of the chart in the temp directory with the new `crds/`,
   `templates/` and `values.yaml`.
5. Updates the staged `Chart.yaml`: `version` and `appVersion` from `release.version`, the
   `kubectl-catalog.io/channel` annotation from the channel, and renders `description`
   as a literal block. There is no `catalog-ref` annotation (no catalog in bundle mode).
6. Runs `helm lint` and `helm template --include-crds` on the staged chart.
7. Only if all of the above passed, copies the staged chart over
   `helm-charts/openshift-gitops-operator`. Any earlier failure leaves it untouched.

The workflow uses the bundle image
`quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle:v<release.version>`
(for example `:v1.23.0`), waiting until that tag exists on quay.io.

## Run locally

Requires `kubectl-catalog` (build the commit pinned in `update-helm-charts.yaml`),
`yq` v4 (mikefarah), `helm`, and a pull secret that can read quay.io.

```sh
# one-time: install the pinned kubectl-catalog (see KUBECTL_CATALOG_COMMIT in the workflow)
go install github.com/anandf/kubectl-catalog@<commit>

# log in; the script reads ~/.docker/config.json unless PULL_SECRET is set
podman login quay.io --authfile ~/.docker/config.json

VERSION=$(yq -r '.release.version' config.yaml)

hack/update-helm-chart.sh \
  "quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/gitops-operator-bundle:v${VERSION}"
```

The script edits the working tree only after the staged chart validates. To undo a
successful run: `git checkout helm-charts/ && git clean -fd helm-charts/`.

`hack/update-helm-chart.sh --check-flags` only verifies that `kubectl-catalog` supports
every flag the script uses.

## Generate manually (without the script)

Chart with CRDs, from a catalog channel instead of a bundle:

```sh
kubectl-catalog generate openshift-gitops-operator --channel gitops-1.23 \
  --output-format helm --chart-name openshift-gitops-operator \
  --catalog quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v4.20 \
  --pull-secret ~/keys/pull-secret.txt
```

The output still needs the patches in step 3 above, which only the script applies.
