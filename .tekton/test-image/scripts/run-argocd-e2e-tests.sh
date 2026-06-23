#!/usr/bin/env bash
set -u -o pipefail

# Upstream ArgoCD E2E tests adapted from downstream-CI single-argocd-e2e-test.
# Deploys a test ArgoCD instance in a dedicated namespace, compiles and runs
# the upstream E2E test suite inside the cluster.
#
# Env vars expected: KUBECONFIG, TEST_REPO_URL, BRANCH
#   TEST_REPO_URL should point to the argo-cd repo (default: https://github.com/argoproj/argo-cd.git)
#   BRANCH should be a version tag (e.g. v2.14.0) or "master"

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

ROOT_DIR=$(mktemp -d)
TEST_REPO_URL="${TEST_REPO_URL:-https://github.com/argoproj/argo-cd.git}"
BRANCH="${BRANCH:-master}"

SKIP_FILE=/usr/local/bin/skip-argocd.txt
if [[ -f "$SKIP_FILE" ]]; then
  ARGOCD_E2E_SKIP=$(grep -v '^\s*#' "$SKIP_FILE" | grep -v '^\s*$' | paste -sd '|')
fi
ARGOCD_E2E_SKIP="${ARGOCD_E2E_SKIP:-TestCreateAndUseAccount|TestCanIGetLogs|TestAccountSessionToken}"

ARGO_CD_DIR="${ROOT_DIR}/argo-cd"
export HOME="$ROOT_DIR"
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_TERMINAL_PROMPT=0
export GODEBUG="tarinsecurepath=0,zipinsecurepath=0"
export GOTOOLCHAIN=auto

# shellcheck disable=SC2034 # these are used indirectly via ${!pid_var} in cleanup
LOGGER_PID=""
GIT_FWD_PID=""
TEMP_PF_PID=""
PERMISSION_WATCHER_PID=""
COMPILE_HEARTBEAT_PID=""

cleanup_resources() {
  local exit_code=$?
  echo "Cleaning up..."
  for pid_var in LOGGER_PID GIT_FWD_PID TEMP_PF_PID PERMISSION_WATCHER_PID COMPILE_HEARTBEAT_PID; do
    local pid=${!pid_var}
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done

  # Only restore operator in operator mode
  if [[ "${DEPLOY_MODE:-operator}" != "standalone" ]]; then
    OP_NS=$(oc get deployment -A -l app.kubernetes.io/name=openshift-gitops-operator \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    OP_DEPLOY=$(oc get deployment -A -l app.kubernetes.io/name=openshift-gitops-operator \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$OP_NS" && -n "$OP_DEPLOY" ]]; then
      oc set env "deployment/$OP_DEPLOY" -n "$OP_NS" \
        DISABLE_DEFAULT_ARGOCD_INSTANCE- ARGOCD_CLUSTER_CONFIG_NAMESPACES- 2>/dev/null || true
      oc scale deployment "$OP_DEPLOY" -n "$OP_NS" --replicas=1 2>/dev/null || true
      oc rollout status "deployment/$OP_DEPLOY" -n "$OP_NS" --timeout=120s 2>/dev/null || true
    fi
  fi

  for ns in argocd-e2e argocd-e2e-external argocd-e2e-external-2; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      oc get applications -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        xargs -n1 -I{} oc patch application {} -n "$ns" --type merge \
          -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    fi
  done
  oc delete argocd argocd-test -n argocd-e2e --timeout=30s --ignore-not-found 2>/dev/null || \
    oc patch argocd argocd-test -n argocd-e2e --type json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' --ignore-not-found 2>/dev/null || true
  oc delete ns -l e2e.argoproj.io=true --ignore-not-found --wait=false 2>/dev/null || true
  oc delete project argocd-e2e argocd-e2e-external argocd-e2e-external-2 \
    --ignore-not-found --wait=false 2>/dev/null || true
  for sa in argocd-test-applicationset-controller argocd-test-argocd-application-controller argocd-test-argocd-server; do
    oc delete clusterrolebinding "full-admin-${sa}" --ignore-not-found 2>/dev/null || true
  done

  exit $exit_code
}
trap cleanup_resources EXIT INT TERM

wait_for_port_forward() {
  local ip=$1 port=$2
  for _ in $(seq 1 30); do
    if bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# --- Clone and compile ---

git config --global user.name "Tekton Pipeline"
git config --global user.email "tekton@example.com"
git config --global --add safe.directory "*"

# Detect target cluster architecture for cross-compilation
TARGET_ARCH=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "amd64")
echo "Target cluster architecture: ${TARGET_ARCH}"

TAG="${BRANCH}"
if [[ "${BRANCH}" =~ ^v ]]; then
  TAG="${BRANCH%%+*}"
fi

IMAGE_TAG="${TAG}"
if [[ "${IMAGE_TAG}" == "master" || "${IMAGE_TAG}" == "main" ]]; then
  IMAGE_TAG="latest"
fi

PREBUILT_DIR="/prebuilt/argocd-e2e"
PREBUILT_BRANCH=$(cat "${PREBUILT_DIR}/BRANCH" 2>/dev/null || true)
PREBUILT_ARCH=$(cat "${PREBUILT_DIR}/GOARCH" 2>/dev/null || true)

if [[ -f "${PREBUILT_DIR}/e2e.test" && -f "${PREBUILT_DIR}/argocd" \
      && "${PREBUILT_BRANCH}" == "${TAG}" && "${PREBUILT_ARCH}" == "${TARGET_ARCH}" ]]; then
  echo "Using pre-built artifacts for ${TAG}/${TARGET_ARCH}"
  mkdir -p "${ARGO_CD_DIR}/dist"
  cp "${PREBUILT_DIR}/e2e.test" "${ARGO_CD_DIR}/e2e.test"
  cp "${PREBUILT_DIR}/argocd" "${ARGO_CD_DIR}/dist/argocd"
  cp "${PREBUILT_DIR}/test-fixtures.tar.gz" "${ARGO_CD_DIR}/test-fixtures.tar.gz"
else
  echo "Pre-built artifacts not available (want ${TAG}/${TARGET_ARCH}, have ${PREBUILT_BRANCH:-none}/${PREBUILT_ARCH:-none})"
  echo "Cloning argo-cd from ${TEST_REPO_URL} @ ${BRANCH}"

  git clone --depth 1 "${TEST_REPO_URL}" "${ARGO_CD_DIR}" 2>&1
  cd "${ARGO_CD_DIR}" || exit 1

  if [[ "${BRANCH}" =~ ^v ]]; then
    git fetch --depth 1 origin "tags/$TAG" 2>&1
    git checkout FETCH_HEAD 2>&1
  fi

  mkdir -p "${ROOT_DIR}/go-cache" "${ROOT_DIR}/go-mod"
  export GOCACHE="${ROOT_DIR}/go-cache"
  export GOMODCACHE="${ROOT_DIR}/go-mod"
  export GOARCH="${TARGET_ARCH}"
  export GOOS="linux"

  # Seed from image-baked caches if available
  if [[ -d /usr/local/go-cache/build ]]; then
    cp -a /usr/local/go-cache/build/* "${GOCACHE}/" 2>/dev/null || true
  fi
  if [[ -d /usr/local/go-cache/mod ]]; then
    cp -a /usr/local/go-cache/mod/* "${GOMODCACHE}/" 2>/dev/null || true
  fi

  # shellcheck source=/dev/null
  source /usr/local/bin/go-cache.sh
  go_cache_pull "argocd-${TAG}"

  go mod download

  CLIENT_VERSION=$(cat VERSION 2>/dev/null || echo "${TAG}")
  CLIENT_VERSION="${CLIENT_VERSION#v}"

  echo "Compiling E2E test binary..."
  ( while true; do echo "still compiling..."; sleep 60; done ) &
  COMPILE_HEARTBEAT_PID=$!

  if ! go test -c -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
      -o e2e.test ./test/e2e 2>&1 | tee "${RESULTS_DIR}/compile.log"; then
    kill "$COMPILE_HEARTBEAT_PID" 2>/dev/null || true
    echo "ERROR: test compilation failed"
    exit 1
  fi
  kill "$COMPILE_HEARTBEAT_PID" 2>/dev/null || true

  go build -ldflags "-X github.com/argoproj/argo-cd/v3/common.version=${CLIENT_VERSION}" \
    -o "${ARGO_CD_DIR}/dist/argocd" ./cmd 2>&1

  go_cache_push "argocd-${TAG}"
fi

# --- Configure operator for test namespace (or standalone mode) ---

DEPLOY_MODE="${DEPLOY_MODE:-operator}"

OP_NS=""
OP_DEPLOY=""

# Determine ArgoCD image to use
if [[ -n "${ARGOCD_IMAGE:-}" ]]; then
  # ARGOCD_IMAGE explicitly provided (from SNAPSHOT in standalone mode)
  echo "Using explicitly provided ArgoCD image: ${ARGOCD_IMAGE}"
elif [[ -n "${OPENSHIFT_VERSION:-}" ]]; then
  # Build the Konflux argocd image reference from OPENSHIFT_VERSION
  # Using a tag (not a digest) lets the container runtime pick the correct arch
  MINOR_VERSION=$(echo "${OPENSHIFT_VERSION}" | grep -oP '^\d+\.\d+')
  ARGOCD_IMAGE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/argocd-rhel9:v${MINOR_VERSION}"
  echo "Built ArgoCD image from OPENSHIFT_VERSION: ${ARGOCD_IMAGE}"
else
  ARGOCD_IMAGE="quay.io/argoproj/argocd:${IMAGE_TAG}"
  echo "Using upstream ArgoCD image: ${ARGOCD_IMAGE}"
fi

if [[ "${DEPLOY_MODE}" != "standalone" ]]; then
  # Operator mode: discover and configure the operator
  OP_NS=$(oc get deployment -A -l app.kubernetes.io/name=openshift-gitops-operator \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
  OP_DEPLOY=$(oc get deployment -A -l app.kubernetes.io/name=openshift-gitops-operator \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$OP_NS" && -n "$OP_DEPLOY" ]]; then
    oc set env "deployment/$OP_DEPLOY" -n "$OP_NS" \
      DISABLE_DEFAULT_ARGOCD_INSTANCE=true \
      ARGOCD_CLUSTER_CONFIG_NAMESPACES=openshift-gitops,argocd-e2e -c manager || true
    oc rollout status "deployment/$OP_DEPLOY" -n "$OP_NS" --timeout=60s || true
  fi
fi

if oc get project argocd-e2e >/dev/null 2>&1; then
  oc patch argocd argocd-test -n argocd-e2e -p '{"metadata":{"finalizers":[]}}' \
    --type=merge --ignore-not-found 2>/dev/null || true
  oc delete project argocd-e2e --ignore-not-found --wait=true 2>/dev/null
fi
oc new-project argocd-e2e

oc -n argocd-e2e adm policy add-scc-to-user privileged -z default 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin -z default -n argocd-e2e 2>/dev/null || true

# --- Deploy test ArgoCD instance ---

echo "Deploying test ArgoCD instance (mode: ${DEPLOY_MODE})..."
oc create namespace argocd-e2e-external --dry-run=client -o yaml | oc apply -f -
oc label namespace argocd-e2e-external e2e.argoproj.io=true --overwrite 2>/dev/null || true

if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  # Standalone mode: deploy ArgoCD from upstream manifests without operator
  echo "Standalone mode: deploying ArgoCD from upstream manifests"

  # Apply CRDs first
  oc apply -f "${ARGO_CD_DIR}/manifests/crds/" -n argocd-e2e 2>/dev/null || true

  # Prepare install.yaml with our image and namespace
  cp "${ARGO_CD_DIR}/manifests/install.yaml" "${ROOT_DIR}/install-patched.yaml"

  # Replace upstream image with SNAPSHOT image
  sed -i "s|quay.io/argoproj/argocd:.*|${ARGOCD_IMAGE}|g" "${ROOT_DIR}/install-patched.yaml"

  # Replace namespace references
  sed -i '/^  namespace: argocd$/s/argocd/argocd-e2e/' "${ROOT_DIR}/install-patched.yaml"

  # Apply install.yaml
  oc apply -f "${ROOT_DIR}/install-patched.yaml" -n argocd-e2e

  # Wait for deployments
  echo "Waiting for ArgoCD deployments..."
  for _ in {1..30}; do
    if oc get deployment argocd-server -n argocd-e2e >/dev/null 2>&1; then break; fi
    sleep 2
  done
  oc wait --for=condition=Available deployment/argocd-server -n argocd-e2e --timeout=300s || true
  oc wait --for=condition=Available deployment/argocd-repo-server -n argocd-e2e --timeout=300s || true

  # Wait for application controller (can be deployment or statefulset)
  oc rollout status deployment/argocd-application-controller -n argocd-e2e --timeout=300s 2>/dev/null || \
    oc rollout status statefulset/argocd-application-controller -n argocd-e2e --timeout=300s 2>/dev/null || true

  echo "Standalone ArgoCD deployed successfully"

else
  # Operator mode: deploy via ArgoCD CR
  cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: argocd-test
  namespace: argocd-e2e
spec:
  sourceNamespaces:
    - "argocd-e2e-external"
    - "argocd-e2e-external-2"
  server:
    insecure: true
    route: { enabled: false }
  rbac:
    defaultPolicy: 'role:admin'
  applicationSet: {}
  controller:
    env:
      - name: ARGOCD_K8S_CLIENT_QPS
        value: "300"
      - name: ARGOCD_K8S_CLIENT_BURST
        value: "600"
EOF

  for _ in {1..30}; do
    if oc get deployment argocd-test-server -n argocd-e2e >/dev/null 2>&1; then break; fi
    sleep 2
  done
  oc wait --for=condition=Available deployment/argocd-test-server -n argocd-e2e --timeout=180s || true
  oc wait --for=condition=Available deployment/argocd-test-repo-server -n argocd-e2e --timeout=120s || true

  # Extract the actual image the operator used
  OPERATOR_IMAGE=$(oc get deployment argocd-test-repo-server -n argocd-e2e \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [[ -n "$OPERATOR_IMAGE" ]]; then
    echo "Overriding ARGOCD_IMAGE with operator-deployed image: ${OPERATOR_IMAGE}"
    ARGOCD_IMAGE="${OPERATOR_IMAGE}"
  else
    echo "WARNING: Could not extract image from argocd-test-repo-server, using: ${ARGOCD_IMAGE}"
  fi

  echo "Pausing operator reconciliation..."
  oc annotate argocd argocd-test -n argocd-e2e \
    argocd.argoproj.io/operator-pause-reconciliation="true" --overwrite

  echo "Scaling down operators to lock config state..."
  oc scale deploy -l app.kubernetes.io/name=openshift-gitops-operator -A --replicas=0 2>/dev/null || true
  oc scale deploy -l app.kubernetes.io/part-of=argocd-operator -A --replicas=0 2>/dev/null || true
  if [[ -n "$OP_NS" ]]; then
    oc scale deploy -n "$OP_NS" --all --replicas=0 2>/dev/null || true
  fi
  sleep 5
fi

oc delete secret -n argocd-e2e -l argocd.argoproj.io/secret-type=cluster --ignore-not-found 2>/dev/null || true

# Cluster secret name varies by deployment mode
CLUSTER_SECRET_NAME="argocd-test-default-cluster-config"
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  CLUSTER_SECRET_NAME="argocd-default-cluster-config"
fi

cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: v1
kind: Secret
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster
  name: ${CLUSTER_SECRET_NAME}
stringData:
  config: '{"tlsClientConfig":{"insecure":false}}'
  name: in-cluster
  namespaces: ""
  server: https://kubernetes.default.svc
EOF

# ConfigMaps: patch in standalone mode (already exist), create in operator mode
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  # Standalone: patch existing configmaps created by install.yaml
  oc patch configmap argocd-cm -n argocd-e2e --type merge \
    -p '{"data":{"url":"https://argocd-server","server.insecure":"true"}}' 2>/dev/null || true
  oc patch configmap argocd-cmd-params-cm -n argocd-e2e --type merge \
    -p '{"data":{"server.insecure":"true"}}' 2>/dev/null || true
else
  # Operator mode: create configmaps
  cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
data:
  url: "https://argocd-test-server"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  server.insecure: "true"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
data: {}
EOF
fi

# Service accounts: use unprefixed names in standalone, prefixed in operator mode
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  for sa in argocd-applicationset-controller argocd-application-controller argocd-server; do
    oc create clusterrolebinding "full-admin-${sa}" \
      --clusterrole=cluster-admin "--serviceaccount=argocd-e2e:${sa}" \
      --dry-run=client -o yaml | oc apply -f -
  done
else
  for sa in argocd-test-applicationset-controller argocd-test-argocd-application-controller argocd-test-argocd-server; do
    oc create clusterrolebinding "full-admin-${sa}" \
      --clusterrole=cluster-admin "--serviceaccount=argocd-e2e:${sa}" \
      --dry-run=client -o yaml | oc apply -f -
  done
fi

oc apply -f https://raw.githubusercontent.com/open-cluster-management/api/a6845f2ebcb186ec26b832f60c988537a58f3859/cluster/v1alpha1/0000_04_clusters.open-cluster-management.io_placementdecisions.crd.yaml 2>/dev/null || true

# ApplicationSet controller configuration
APPSET_DEPLOY="argocd-test-applicationset-controller"
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  APPSET_DEPLOY="argocd-applicationset-controller"
fi

oc scale deployments "${APPSET_DEPLOY}" -n argocd-e2e --replicas=0 2>/dev/null || true
oc set env "deploy/${APPSET_DEPLOY}" -n argocd-e2e \
  -c argocd-applicationset-controller \
  ARGOCD_APPLICATIONSET_CONTROLLER_ALLOWED_SCM_PROVIDERS=https://github.com/ \
  ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES=argocd-e2e-external,argocd-e2e 2>/dev/null || true
oc scale deployments "${APPSET_DEPLOY}" -n argocd-e2e --replicas=1 2>/dev/null || true

cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
spec:
  sourceRepos:
    - "*"
  destinations:
    - server: "*"
      namespace: "*"
  sourceNamespaces:
    - "argocd-e2e-external"
    - "argocd-e2e-external-2"
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
EOF

echo "Bouncing ArgoCD components..."
oc delete pod -l app.kubernetes.io/name=argocd-application-controller -n argocd-e2e --ignore-not-found --wait=false || true
oc delete pod -l app.kubernetes.io/name=argocd-server -n argocd-e2e --ignore-not-found --wait=false || true
oc delete pod -l app.kubernetes.io/name=argocd-applicationset-controller -n argocd-e2e --ignore-not-found --wait=false || true

echo "Waiting for ArgoCD to stabilize..."
# Resource names vary by deployment mode
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  APP_CONTROLLER="argocd-application-controller"
  SERVER="argocd-server"
  APPSET_CONTROLLER="argocd-applicationset-controller"
else
  APP_CONTROLLER="argocd-test-application-controller"
  SERVER="argocd-test-server"
  APPSET_CONTROLLER="argocd-test-applicationset-controller"
fi

if oc get statefulset "${APP_CONTROLLER}" -n argocd-e2e >/dev/null 2>&1; then
  oc rollout status "statefulset/${APP_CONTROLLER}" -n argocd-e2e --timeout=300s
else
  oc rollout status "deployment/${APP_CONTROLLER}" -n argocd-e2e --timeout=300s
fi
oc rollout status "deployment/${SERVER}" -n argocd-e2e --timeout=300s
oc rollout status "deployment/${APPSET_CONTROLLER}" -n argocd-e2e --timeout=300s

# --- Set up git server ---

cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: v1
kind: Pod
metadata: { name: git-server, labels: { app: git-server } }
spec:
  serviceAccountName: default
  containers:
  - name: git-server
    image: bitnami/git:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        mkdir -p /git/testdata.git && cd /git/testdata.git && git init --bare && touch git-daemon-export-ok && \
        git daemon --base-path=/git --export-all --enable=receive-pack --port=9418 --verbose
    ports: [ { containerPort: 9418 } ]
    volumeMounts: [ { name: git-volume, mountPath: /git } ]
    securityContext: { runAsUser: 0 }
  volumes: [ { name: git-volume, emptyDir: {} } ]
---
apiVersion: v1
kind: Service
metadata: { name: git-server }
spec: { selector: { app: git-server }, ports: [ { port: 9418, targetPort: 9418 } ] }
EOF

oc wait --for=condition=Ready pod/git-server -n argocd-e2e --timeout=120s

# --- Set up test runner pod ---

cat <<EOF | oc apply -n argocd-e2e -f -
apiVersion: v1
kind: Pod
metadata:
  name: e2e-test-runner
  namespace: argocd-e2e
spec:
  serviceAccountName: default
  containers:
  - name: runner
    image: ${ARGOCD_IMAGE}
    command: ["/bin/sh", "-c", "tail -f /dev/null"]
EOF

oc wait --for=condition=Ready pod/e2e-test-runner -n argocd-e2e --timeout=180s
oc exec -n argocd-e2e e2e-test-runner -- mkdir -p /tmp/argo-cd/dist /tmp/bin

cd "${ARGO_CD_DIR}" || exit 1
if [[ ! -f test-fixtures.tar.gz ]]; then
  tar -czf test-fixtures.tar.gz test/
fi
oc cp "${ARGO_CD_DIR}/e2e.test" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/"
oc cp "${ARGO_CD_DIR}/test-fixtures.tar.gz" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/"
oc exec -n argocd-e2e e2e-test-runner -- sh -c "cd /tmp/argo-cd && tar -xzf test-fixtures.tar.gz && rm test-fixtures.tar.gz"

# Copy argocd CLI from the Konflux-built image to the path the tests expect (../../dist/argocd)
ARGOCD_BIN=$(oc exec -n argocd-e2e e2e-test-runner -- sh -c 'command -v argocd' 2>/dev/null)
if [[ -n "$ARGOCD_BIN" ]]; then
  echo "Copying argocd CLI from image (${ARGOCD_BIN}) to /tmp/argo-cd/dist/"
  oc exec -n argocd-e2e e2e-test-runner -- cp "$ARGOCD_BIN" /tmp/argo-cd/dist/argocd
  if ! oc exec -n argocd-e2e e2e-test-runner -- /tmp/argo-cd/dist/argocd version --client --short 2>/dev/null; then
    echo "WARNING: argocd from image failed to execute (arch mismatch?), using compiled binary"
    oc cp "${ARGO_CD_DIR}/dist/argocd" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/dist/"
  fi
else
  echo "WARNING: argocd not found in image, falling back to compiled binary"
  oc cp "${ARGO_CD_DIR}/dist/argocd" "argocd-e2e/e2e-test-runner:/tmp/argo-cd/dist/"
fi

# Get a real kubectl for the test runner pod (must match cluster node arch, not pipeline pod arch).
# Pipeline pod is x86_64, cluster nodes are typically arm64 — never copy the pipeline pod's own binaries.
# Try well-known binary paths directly — `command -v` may not work in minimal containers.
KUBECTL_FOUND=false
for bin_candidate in /usr/local/bin/kubectl /usr/bin/kubectl /usr/local/bin/oc /usr/bin/oc; do
  if oc exec -n argocd-e2e e2e-test-runner -- test -x "$bin_candidate" 2>/dev/null; then
    echo "Found ${bin_candidate} in test runner image, copying to /tmp/bin/kubectl"
    oc exec -n argocd-e2e e2e-test-runner -- cp "$bin_candidate" /tmp/bin/kubectl
    KUBECTL_FOUND=true
    break
  fi
done

if [[ "$KUBECTL_FOUND" != "true" ]]; then
  echo "kubectl/oc not found in image, downloading kubectl v1.30.0 for ${TARGET_ARCH}"
  curl -fsSL "https://dl.k8s.io/release/v1.30.0/bin/linux/${TARGET_ARCH}/kubectl" \
    -o /tmp/kubectl-download
  oc cp /tmp/kubectl-download "argocd-e2e/e2e-test-runner:/tmp/bin/kubectl"
  rm -f /tmp/kubectl-download
fi

oc exec -n argocd-e2e e2e-test-runner -- chmod +x /tmp/bin/kubectl
if ! oc exec -n argocd-e2e e2e-test-runner -- /tmp/bin/kubectl version --client 2>&1; then
  echo "ERROR: kubectl at /tmp/bin/kubectl failed to execute"
  oc exec -n argocd-e2e e2e-test-runner -- file /tmp/bin/kubectl 2>/dev/null || true
  exit 1
fi

# --- Verify git push works ---

( while true; do oc -n argocd-e2e port-forward service/git-server 9418:9418 >/dev/null 2>&1; sleep 1; done ) &
# shellcheck disable=SC2034 # used via ${!pid_var} in cleanup
GIT_FWD_PID=$!
wait_for_port_forward "127.0.0.1" 9418 || exit 1

VERIFY_DIR=$(mktemp -d)
cd "$VERIFY_DIR" || exit 1
git init && touch test-file && git add test-file && git commit -m "verify push" >/dev/null
git push "git://127.0.0.1:9418/testdata.git" master:verify-branch 2>&1 || true

# --- Get API token ---

# Admin password secret name and server service vary by deployment mode
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  ADMIN_SECRET="argocd-initial-admin-secret"
  ADMIN_SECRET_KEY="password"
  SERVER_SERVICE="argocd-server"
  SERVER_PORT="8080"
else
  ADMIN_SECRET="argocd-test-cluster"
  ADMIN_SECRET_KEY="admin.password"
  SERVER_SERVICE="argocd-test-server"
  SERVER_PORT="80"
fi

ADMIN_PASS=$(oc -n argocd-e2e get secrets "${ADMIN_SECRET}" -o jsonpath="{.data.${ADMIN_SECRET_KEY}}" | base64 -d)
( while true; do oc -n argocd-e2e port-forward "service/${SERVER_SERVICE}" "8080:${SERVER_PORT}" >/dev/null 2>&1; sleep 1; done ) &
TEMP_PF_PID=$!
wait_for_port_forward "127.0.0.1" 8080 || exit 1

TOKEN_JSON=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" \
  "http://127.0.0.1:8080/api/v1/session")
ARGOCD_AUTH_TOKEN=$(echo "$TOKEN_JSON" | grep -o '"token":"[^"]*"' | sed 's/"token"://g' | tr -d '"')
kill "$TEMP_PF_PID" 2>/dev/null || true
TEMP_PF_PID=""

# --- Background namespace watcher ---

(
  while true; do
    CURRENT_NS=$(oc get secret "${CLUSTER_SECRET_NAME}" -n argocd-e2e \
      -o jsonpath='{.data.namespaces}' 2>/dev/null | base64 -d 2>/dev/null || echo "argocd-e2e")

    for ns in $(oc get ns -l e2e.argoproj.io=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      if ! oc get ns "$ns" -o jsonpath='{.metadata.labels}' | grep -q 'argocd.argoproj.io/managed-by'; then
        oc label ns "$ns" argocd.argoproj.io/managed-by=argocd-e2e --overwrite >/dev/null 2>&1 || true
      fi
      if [[ "$CURRENT_NS" != *"$ns"* ]]; then
        echo "Whitelisting new test namespace: $ns"
        NEW_NS="${CURRENT_NS},${ns}"
        oc patch secret "${CLUSTER_SECRET_NAME}" -n argocd-e2e \
          --type='merge' -p="{\"stringData\":{\"namespaces\":\"$NEW_NS\"}}" >/dev/null 2>&1 || true
        (
          sleep 2
          for app in $(oc get application -n argocd-e2e -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            oc annotate application "$app" -n argocd-e2e \
              argocd.argoproj.io/refresh="hard" --overwrite >/dev/null 2>&1 || true
          done
        ) &
      fi
    done
    sleep 1
  done
) &
# shellcheck disable=SC2034 # used via ${!pid_var} in cleanup
PERMISSION_WATCHER_PID=$!

# --- Run tests ---

echo "Running all ArgoCD E2E tests (mode: ${DEPLOY_MODE})..."

# Set env vars based on deployment mode
if [[ "${DEPLOY_MODE}" == "standalone" ]]; then
  NAME_PREFIX=""
  API_SERVER_URL="https://argocd-server"
  ARGOCD_SERVER_ADDR="argocd-server.argocd-e2e.svc.cluster.local:8080"
else
  NAME_PREFIX="argocd-test"
  API_SERVER_URL="https://argocd-test-server"
  ARGOCD_SERVER_ADDR="argocd-test-server.argocd-e2e.svc.cluster.local:80"
fi

cat <<REMOTE_SCRIPT > "${ROOT_DIR}/run_test_remote.sh"
#!/usr/bin/env sh

export PATH=/tmp/argo-cd/dist:/tmp/bin:\$PATH
export NAMESPACE=argocd-e2e
export ARGOCD_E2E_NAMESPACE=\$NAMESPACE
export ARGOCD_E2E_NAME_PREFIX=${NAME_PREFIX}
export ARGOCD_E2E_REMOTE=true
export ARGOCD_E2E_WAIT_TIMEOUT=120

export ARGOCD_E2E_SKIP_SETUP=true
export ARGOCD_E2E_REUSE_SERVER=true
export ARGOCD_E2E_APISERVER_URL="${API_SERVER_URL}"

export ARGOCD_SERVER="${ARGOCD_SERVER_ADDR}"
export ARGOCD_SERVER_INSECURE=true
export ARGOCD_E2E_INSECURE=true

export ARGOCD_AUTH_TOKEN="$ARGOCD_AUTH_TOKEN"
export ARGOCD_E2E_ADMIN_PASSWORD="$ADMIN_PASS"
export DIST_DIR="/tmp/argo-cd/dist"

export ARGOCD_E2E_GIT_SERVICE="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"
export ARGOCD_E2E_REPO_DEFAULT="git://git-server.argocd-e2e.svc.cluster.local:9418/testdata.git"

export ARGOCD_E2E_DIR="/tmp/argo-e2e"

export ARGOCD_GPG_ENABLED=true
export ARGOCD_E2E_SKIP_GPG=true
export ARGOCD_E2E_SKIP_HELM2=true
export ARGOCD_E2E_SKIP_OPENSHIFT=true
export ARGOCD_E2E_SKIP_KSONNET=true
export GRPC_ENFORCE_ALPN_ENABLED=false
export NO_PROXY="*"

git config --global user.email "test@example.com"
git config --global user.name "Test Runner"
git config --global --add safe.directory "*"

cd /tmp/argo-cd/test/e2e

SKIP_PATTERN="${ARGOCD_E2E_SKIP}"
if [ -n "\$SKIP_PATTERN" ]; then
  /tmp/argo-cd/e2e.test -test.v -test.timeout 120m -test.skip "\$SKIP_PATTERN"
else
  /tmp/argo-cd/e2e.test -test.v -test.timeout 120m
fi
REMOTE_SCRIPT

oc cp "${ROOT_DIR}/run_test_remote.sh" "argocd-e2e/e2e-test-runner:/tmp/run_test_remote.sh"
TEST_EXIT_CODE=0
oc exec -n argocd-e2e e2e-test-runner -- sh /tmp/run_test_remote.sh 2>&1 | tee "${RESULTS_DIR}/argocd-e2e.log" || TEST_EXIT_CODE=$?

FAIL_COUNT=$(grep -c "^--- FAIL:" "${RESULTS_DIR}/argocd-e2e.log" 2>/dev/null || echo "0")
PASS_COUNT=$(grep -c "^--- PASS:" "${RESULTS_DIR}/argocd-e2e.log" 2>/dev/null || echo "0")

for component in argocd-test-server application-controller applicationset-controller; do
  POD=$(oc get pods -n argocd-e2e 2>/dev/null | grep "$component" | awk '{print $1}' | head -1)
  if [[ -n "$POD" ]]; then
    echo "--- $component logs (tail) ---"
    oc logs -n argocd-e2e "$POD" --tail=50 2>/dev/null | tee "${RESULTS_DIR}/${component}.log" || true
  fi
done

echo "========================================"
echo "ArgoCD E2E results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (exit code ${TEST_EXIT_CODE})"
echo "========================================"

if [[ "$TEST_EXIT_CODE" -ne 0 || "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
