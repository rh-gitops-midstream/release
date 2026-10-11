# Argo CD Extension Installer

`extensions-Rollout.js` is kept in sync automatically by `hack/sync-sources.sh`, which downloads the release tarball from https://github.com/argoproj-labs/rollout-extension/releases for the version pinned in `config.yaml` (`sources/rollout-extension.ref`) and extracts the JS file.

To update the extension, bump the `ref` and `commit` for `sources/rollout-extension` in `config.yaml` and re-run `./hack/sync-sources.sh`.

### TODO: Build extension from source in Dockerfile instead of using prebuilt js
