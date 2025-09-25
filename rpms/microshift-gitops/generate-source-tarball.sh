#!/usr/bin/env bash
set -euxo pipefail

echo "Running tarball script"

#tar -czvf ./rpms/microshift-gitops/argocd-sources.tar.gz -C ./sources argo-cd

#ls -l ./rpms/microshift-gitops/

mv ./rpms/microshift-gitops/microshift-gitops.spec .
tar -czvf argo-cd-sources.tar.gz -C ./sources argo-cd
rm -rf ./sources