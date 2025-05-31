# Copyright 2023 Red Hat
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
FROM registry.redhat.io/openshift4/ose-must-gather:v4.13.0

LABEL \
    name="openshift-gitops-1/must-gather-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-must-gather-container" \
    com.redhat.delivery.appregistry="false" \ 
    upstream-vcs-type="git" \
    summary="OpenShift GitOps Must Gather" \
    description="Red Hat OpenShift GitOps Must Gather" \
    maintainer="William Tam <wtam@redhat.com>" \
    io.k8s.display-name="Red Hat OpenShift GitOps Must Gather"\
    io.openshift.tags="openshift,gitops-operator, must-gather" \
    io.openshift.maintainer.product="Red Hat OpenShift GitOps" \
    io.k8s.description="Red Hat OpenShift GitOps Must Gather" \
    io.openshift.maintainer.component="William Tam <wtam@redhat.com>"  
    
# Save original gather script
RUN mv /usr/bin/gather /usr/bin/gather_original

COPY sources/gitops-must-gather/gather_gitops.sh /usr/bin/gather

# Make it executable
RUN chmod +x /usr/bin/gather

ENTRYPOINT /usr/bin/gather