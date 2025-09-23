#!/usr/bin/env bash
set -euxo pipefail

tar -czvf ./rpm/microshift/argocd-sources.tar.gz -C ./sources argo-cd

ls -l ./rpm/microshift/