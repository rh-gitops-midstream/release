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

FROM registry.access.redhat.com/ubi9/nodejs-22 AS builder

USER root

# Install pnpm via npm prefetch bootstrap (same pattern as prefetch/pnpm)
WORKDIR /workspace
COPY ["prefetch/pnpm/package.json", "prefetch/pnpm/package-lock.json", "./"]
RUN npm install --prefer-offline --no-progress --non-interactive
ENV PATH="/workspace/node_modules/.bin:${PATH}"
RUN pnpm --version
# packageManager in gitops-console-plugin pins pnpm@10.33.2; use bootstrapped pnpm offline.
RUN pnpm config set manage-package-manager-versions false

# Build Console Plugin Dependencies
WORKDIR /workspace/gitops-console-plugin

COPY ["sources/gitops-console-plugin-4.18/package.json", "sources/gitops-console-plugin-4.18/pnpm-lock.yaml", "sources/gitops-console-plugin-4.18/.npmrc", "./"]
RUN pnpm install --frozen-lockfile --offline

COPY ["sources/gitops-console-plugin-4.18/", "."]

RUN NODE_ONLINE_ENV='offline' NODE_ENV='production' pnpm build

####################################################################################################

FROM registry.access.redhat.com/ubi9/httpd-24
USER root
RUN chown -R 1001:0 /opt/app-root/src
USER 1001
RUN chmod g+rwx /opt/app-root/src

RUN mkdir -p /var/www/html
COPY --from=builder /workspace/gitops-console-plugin/ssl.conf /etc/httpd/conf.d
COPY --from=builder /workspace/gitops-console-plugin/dist /var/www/html/plugin

CMD run-httpd

LABEL \
    name="openshift-gitops-1/console-plugin-4.18-rhel9" \
    cpe="cpe:/a:redhat:openshift_gitops-4.18:99.99::el9" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-console-plugin-4.18-container" \
    com.redhat.delivery.appregistry="false" \
    upstream-vcs-type="git" \
    summary="Red Hat OpenShift GitOps Console Plugin for OCP 4.18" \
    maintainer="William Tam <wtam@redhat.com>" \
    io.openshift.tags="openshift,gitops-console-plugin-4.18" \
    io.k8s.display-name="Red Hat OpenShift GitOps Console Plugin for OCP 4.18" \
    io.k8s.description="Red Hat OpenShift GitOps Console Plugin for OCP 4.18" \
    io.openshift.maintainer.product="Red Hat OpenShift GitOps" \
    io.openshift.maintainer.component="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Console Plugin for OCP 4.18"
