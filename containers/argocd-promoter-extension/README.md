# Argo CD GitOps Promoter Extension Installer

`extension-promoter.js` is kept in sync automatically by `hack/sync-sources.sh`, which downloads the release tarball from https://github.com/argoproj-labs/gitops-promoter/releases for the version pinned in `config.yaml` (`sources/gitops-promoter.ref`) and extracts the JS file.

To update the extension, bump the `ref` and `commit` for `sources/gitops-promoter` in `config.yaml` and re-run `./hack/sync-sources.sh`.

This uses the same install script that is located inside of the rollouts extension.

### TODO: Build extension from source in Dockerfile instead of using prebuilt js
