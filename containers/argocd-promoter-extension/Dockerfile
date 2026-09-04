# Copyright 2026 Red Hat
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
# Promoter Extension UI
####################################################################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal as promoter-extension

USER root

COPY containers/argocd-extensions/install.sh /app/install.sh

RUN microdnf install -y tar && microdnf clean all

WORKDIR /app/promoter-extension/ui
RUN mkdir -p dist && mkdir -p resources

COPY containers/argocd-promoter-extension/extension-promoter.js resources/extension-promoter.js

RUN tar cvf dist/extension.tar resources

####################################################################################################
# Final Image
####################################################################################################
FROM registry.access.redhat.com/ubi9/ubi-minimal

ARG USER=ext-installer
ENV HOME=/home/$USER

RUN microdnf install -y file jq shadow-utils tar && microdnf clean all

WORKDIR $HOME

COPY --from=promoter-extension /app/promoter-extension/ui/dist/extension.tar promoter-extension.tar
COPY --from=promoter-extension /app/install.sh install.sh

ENV EXTENSION_NAME="Promoter"
ENV EXTENSION_URL="file://$HOME/promoter-extension.tar"
ENV EXTENSION_VERSION="0.35.0"

ENTRYPOINT ["./install.sh"]

LABEL \
    name="openshift-gitops-1/argocd-promoter-extension-rhel9" \
    cpe="cpe:/a:redhat:openshift_gitops:99.99::el9" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argocd-promoter-extension-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Argo CD Promoter UI Extension" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,extensions,argocd,gitops-promoter" \
    io.k8s.display-name="Red Hat OpenShift GitOps Argo CD Promoter UI Extension" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps GitOps Promoter UI Extension" \
    io.k8s.description="Red Hat OpenShift GitOps Argo CD Promoter UI Extension"
