# Copyright 2024 Red Hat
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ------------------------------------------------------------------------

####################################################################################################
# Rollouts Extensions UI stage
####################################################################################################
FROM registry.access.redhat.com/ubi8/ubi-minimal as rollout-extensions

USER root

COPY sources/rollout-extension /app/rollout-extension
COPY argocd-extension-installer/install.sh /app/install.sh

RUN microdnf install -y tar && microdnf clean all

WORKDIR /app/rollout-extension/ui
RUN mkdir -p dist && mkdir -p resources/extension-Rollout.js

COPY argocd-extension-installer/extensions-Rollout.js resources/extension-Rollout.js

RUN tar cvf dist/extension.tar resources

####################################################################################################
# Final Image
####################################################################################################
FROM registry.access.redhat.com/ubi8/ubi-minimal

ARG USER=ext-installer
ENV HOME=/home/$USER

RUN microdnf install -y file jq shadow-utils tar && microdnf clean all

WORKDIR $HOME

COPY --from=rollout-extensions /app/rollout-extension/ui/dist/extension.tar rollout-extension.tar
COPY --from=rollout-extensions /app/install.sh install.sh

ENV EXTENSION_NAME="Rollout"
ENV EXTENSION_URL="file://$HOME/rollout-extension.tar"
ENV EXTENSION_VERSION="0.3.6"

ENTRYPOINT ["./install.sh"]

LABEL \
    name="openshift-gitops-1/argocd-extensions-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argocd-extensions-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Argocd Extensions" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,extensions,argocd" \
    io.k8s.display-name="Red Hat OpenShift GitOps ArgoCD Extensions" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps ArgoCD Extensions" \
    io.k8s.description="Red Hat OpenShift GitOps ArgoCD Extensions"