FROM scratch

# Core bundle labels.
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=openshift-gitops-operator
LABEL operators.operatorframework.io.bundle.channels.v1=latest,gitops-99.99
LABEL operators.operatorframework.io.bundle.channel.default.v1=latest
LABEL operators.operatorframework.io.metrics.builder=operator-sdk-v1.35.0
LABEL operators.operatorframework.io.metrics.mediatype.v1=metrics+v1
LABEL operators.operatorframework.io.metrics.project_layout=go.kubebuilder.io/v4

# Labels for testing.
LABEL operators.operatorframework.io.test.mediatype.v1=scorecard+v1
LABEL operators.operatorframework.io.test.config.v1=tests/scorecard/

# Copy files to locations specified by labels.
COPY containers/gitops-operator-bundle/bundle/manifests /manifests/
COPY containers/gitops-operator-bundle/bundle/metadata /metadata/
COPY containers/gitops-operator-bundle/bundle/tests/scorecard /tests/scorecard/

LABEL \
    name="openshift-gitops-1/gitops-rhel8-operator" \
    url="" \
    vendor="Red Hat, Inc." \
    com.redhat.component="openshift-gitops-operator-bundle-container" \
    description="Red Hat OpenShift GitOps Operator Bundle" \
    distribution-scope="restricted" \
    io.k8s.description="Red Hat OpenShift GitOps Operator Bundle" \