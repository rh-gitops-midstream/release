#!/usr/bin/env bash
set -euxo pipefail

echo "Running tarball script"

tar -czvf ./rpm/microshift/argocd-sources.tar.gz -C ./sources argo-cd

ls -l ./rpm/microshift/