#!/usr/bin/env bash

# update image and image tag

NEW_IMAGE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-agent-rhel8"

#TODO get release tag from env var RELEASE_BRANCH
RELEASE_TAG=$RELEASE_BRANCH

NEW_IMAGE_DIGEST=$(skopeo inspect --override-os linux --override-arch amd64  docker://${NEW_IMAGE}:${RELEASE_TAG}  | yq '.Digest')

CI_VALUES_FILE="helm-chart/argocd-agent-agent/PR-values.yaml"
DOWNSTERAM_VALUES_FILE="helm-chart/argocd-agent-agent/downstream-values.yaml"

# update the image in values file for both PRs and downstream 
yq  -i ".imageTag = \"$NEW_IMAGE_DIGEST\""  "$CI_VALUES_FILE"
yq  -i ".imageTag = \"$NEW_IMAGE_DIGEST\""  "$DOWNSTERAM_VALUES_FILE"



