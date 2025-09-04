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

FROM registry.redhat.io/rhel8/go-toolset:1.24.6  AS builder
USER root

ENV LANG=en_US.utf8
ENV GIT_COMMITTER_NAME devtools
ENV GIT_COMMITTER_EMAIL devtools@redhat.com
LABEL com.redhat.delivery.appregistry=true

COPY sources/argocd-agent /app/argocd-agent
WORKDIR /app/argocd-agent

RUN CGO_ENABLED=0 go build -mod=mod -o dist/argocd-agent -ldflags "-extldflags=-static" ./cmd/argocd-agent

FROM registry.access.redhat.com/ubi8/ubi-minimal

COPY --from=builder /app/argocd-agent/dist/argocd-agent /bin/argocd-agent
ENTRYPOINT ["./bin/argocd-agent"]

USER 999

LABEL \
    name="openshift-gitops-1/argocd-agent-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-argocd-agent-container" \
    com.redhat.delivery.appregistry="false" \
    summary="Red Hat OpenShift GitOps Argo CD Agent" \
    upstream-vcs-type="git" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops,argocd,agent" \
    io.k8s.display-name="openshift-gitops-argo-agent" \
    io.k8s.description="Red Hat OpenShift GitOps Argo CD Agent" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Argo CD Agent"