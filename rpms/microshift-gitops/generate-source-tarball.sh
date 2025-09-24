#!/usr/bin/env bash
set -euxo pipefail

pwd
ls -l

echo "Running tarball script"

tar -czvf ./rpm/microshift-gitops/argocd-sources.tar.gz -C ./sources argo-cd

ls -l ./rpm/microshift-gitops/