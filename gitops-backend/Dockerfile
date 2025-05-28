# Build Stage
FROM  brew.registry.redhat.io/rh-osbs/openshift-golang-builder:rhel_8_golang_1.23 AS builder

COPY . /app
WORKDIR /app/gitops-backend

RUN GOEXPERIMENT=strictfipsruntime CGO_ENABLED=1 GOOS=linux go build -a -mod=readonly \
  -ldflags "-X github.com/redhat-developer/gitops-backend/pkg/health.GitRevision=$(git rev-parse HEAD)" -tags strictfipsruntime ./cmd/backend-http

# Final Stage
FROM registry.access.redhat.com/ubi8/ubi-minimal
WORKDIR /
COPY --from=builder /app/gitops-backend/backend-http .
EXPOSE 8080
ENTRYPOINT ["./backend-http"]

LABEL \
    name="openshift-gitops-1/gitops-rhel8" \
    License="Apache 2.0" \
    com.redhat.component="openshift-gitops-container" \
    com.redhat.delivery.appregistry="false" \
    upstream-vcs-type="git" \
    summary="Red Hat OpenShift GitOps Backend Service" \
    io.openshift.expose-services="" \
    io.openshift.tags="openshift,gitops" \
    io.k8s.display-name="Red Hat OpenShift GitOps Backend Service" \
    io.k8s.description="Red Hat OpenShift GitOps Backend Service" \
    maintainer="William Tam <wtam@redhat.com>" \
    description="Red Hat OpenShift GitOps Backend Service"