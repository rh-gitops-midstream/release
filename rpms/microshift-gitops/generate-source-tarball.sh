#!/usr/bin/env bash
set -euxo pipefail

pwd
ls -l

echo "Running tarball script"

tar -czvf ./rpms/microshift-gitops/argocd-sources.tar.gz -C ./sources argo-cd

ls -l ./rpms/microshift-gitops/