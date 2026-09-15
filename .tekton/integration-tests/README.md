# Integration Tests

This is a partial port of the `catalog` repo's Konflux integration-test infrastructure
(see [`catalog/.tekton/integration-tests/README.md`](https://github.com/rh-gitops-midstream/catalog/blob/main/.tekton/integration-tests/README.md)
for the full picture — pipeline steps, log storage, results dashboard, skip lists, etc.,
all of which apply here unchanged).

Only the **sanity check** is ported: an `IntegrationTestScenario` that provisions an
ephemeral HyperShift cluster and runs `run-sanity-tests.sh` against a freshly installed
GitOps operator. DAST, UI e2e, ArgoCD upstream e2e, and the full parallel/sequential
Ginkgo suites are not part of this repo — those remain in `catalog`.

## The one real difference: bundle-direct install

`catalog` installs the operator from a full FBC **catalog** image (`CatalogSource` +
`Subscription`, with channels and upgrades). This repo only builds the
**`gitops-operator-bundle`** image directly, so `tasks/install-operator-bundle.yaml` runs

```
operator-sdk run bundle <bundle-image> --namespace <ns> --timeout <timeout>
```

instead. `operator-sdk` resolves the bundle image from the pipeline's `SNAPSHOT` param
(component `gitops-operator-bundle-main` by default — see `BUNDLE_COMPONENT_NAME`) and
manages its own ephemeral index/`CatalogSource` internally. Because a single bundle has
no channel to select or upgrade from, there is no `OPERATOR_CHANNEL`/`UPGRADE` param and
no upgrade step — `get-installed-version.sh` is called with `USE_SUBSCRIPTION=false` to
read the CSV directly instead of via a `Subscription`.

## Layout

```
.tekton/
├── images-mirror-set.yaml                 # ImageDigestMirrorSet, copied from catalog
└── integration-tests/
    ├── pipelines/
    │   └── gitops-operator-bundle-sanity.yaml
    ├── scenarios/
    │   └── gitops-bundle-sanity-tests.yaml   # sanity + sanity-fips
    ├── stepactions/                          # copied verbatim from catalog
    ├── tasks/
    │   ├── install-operator-bundle.yaml      # new: operator-sdk run bundle
    │   └── *.yaml                            # copied verbatim from catalog
    └── test-image/
        ├── Dockerfile.base-v1.21             # byte-identical to catalog's, so the
        ├── Dockerfile.testsuites             # build cache hits catalog's already-
        │                                      # published images and skips rebuilding
        ├── Dockerfile                        # final layer: adds operator-sdk CLI
        └── scripts/
            ├── install-operator-bundle.sh    # new
            └── *.sh / *.py                   # copied verbatim from catalog
```

`Dockerfile.base-v1.21` and `Dockerfile.testsuites` must stay byte-identical to the ones
in `catalog/.tekton/test-image/` — `build-ginkgo-test-image` tags images by content hash,
so an identical Dockerfile reuses the image `catalog` already built and pushed to
`quay.io/devtools_gitops/test_image` instead of rebuilding it.
