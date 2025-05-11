# Copyright 2021 Red Hat
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

FROM registry.access.redhat.com/ubi9/nodejs-22:9.5-1734528986 AS builder

USER root

ADD . /usr/src/app

# Install Yarn
WORKDIR /usr/src/app
RUN npm install --prefer-offline --no-progress --non-interactive
ENV YARN="/usr/src/app/node_modules/.bin/yarn"
RUN $YARN --version

# Install Console Plugin Dependencies
WORKDIR /usr/src/app/gitops-console-plugin
RUN $YARN install --no-progress --non-interactive --prefer-offline --network-timeout 600000 
    
RUN $YARN build
    
####################################################################################################
    
FROM --platform=linux/amd64 registry.redhat.io/ubi9/httpd-24:9.5-1733127463
USER root
RUN chown -R 1001:0 /opt/app-root/src
USER 1001
RUN chmod g+rwx /opt/app-root/src
    
COPY --from=builder /usr/src/app/gitops-console-plugin/ssl.conf /etc/httpd/conf.d
COPY --from=builder /usr/src/app/gitops-console-plugin/dist /var/www/html/plugin
    
CMD run-httpd
    
LABEL \
    name="openshift-gitops-1/gitops-console-plugin-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-console-plugin-container" \
    com.redhat.delivery.appregistry="false" \
    release=${CI_CONTAINER_RELEASE} \
    upstream-vcs-type="git" \
    upstream-version=${CI_UPSTREAM_VERSION} \
    upstream-vcs-ref="${COMMIT_SHA}" \
    version=${CI_CONTAINER_VERSION} \
    summary="Red Hat OpenShift GitOps Console Plugin" \
    maintainer="William Tam <wtam@redhat.com>" \
    io.openshift.tags="openshift,gitops-console-plugin" \
    io.k8s.display-name="Red Hat OpenShift GitOps Console Plugin" \
    io.k8s.description="Red Hat OpenShift GitOps Console Plugin" \
    io.openshift.maintainer.product="Red Hat OpenShift GitOps" \
    io.openshift.maintainer.component="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Console Plugin"
