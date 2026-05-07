#!/bin/bash
set -ex

# Environment variables expected:
# - BUNDLE_IMAGE (from SNAPSHOT, the bundle to install)
# - NAMESPACE (default: openshift-gitops-operator)
# - INSTALL_TIMEOUT (default: 25m)
# - KUBECONFIG

NAMESPACE="${NAMESPACE:-openshift-gitops-operator}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-25m}"

if [[ -z "$BUNDLE_IMAGE" ]]; then
  echo "ERROR: BUNDLE_IMAGE environment variable is required"
  exit 1
fi

echo "=========================================="
echo "Installing GitOps Operator Bundle"
echo "=========================================="
echo "Bundle image: ${BUNDLE_IMAGE}"
echo "Namespace: ${NAMESPACE}"
echo "Timeout: ${INSTALL_TIMEOUT}"
echo ""

# 1. Install operator-sdk
echo "Installing operator-sdk..."
OPERATOR_SDK_VERSION=1.36.1
ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
OPERATOR_SDK_DL_URL=https://github.com/operator-framework/operator-sdk/releases/download/v${OPERATOR_SDK_VERSION}
curl -Lo /tmp/operator-sdk "${OPERATOR_SDK_DL_URL}/operator-sdk_linux_${ARCH}"
chmod +x /tmp/operator-sdk
/tmp/operator-sdk version
echo ""

# 2. Verify cluster connectivity
echo "Verifying cluster connectivity..."
oc status
oc whoami
echo ""

# 3. Create namespace and label it for cluster monitoring
echo "Creating namespace ${NAMESPACE}..."
oc create namespace "${NAMESPACE}" || true
oc label namespaces "${NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite=true
echo ""

# 4. Run operator-sdk run bundle
echo "Running operator-sdk run bundle..."
if ! /tmp/operator-sdk run bundle --timeout="$INSTALL_TIMEOUT" \
  --namespace "${NAMESPACE}" \
  "$BUNDLE_IMAGE" \
  --verbose; then
  echo "ERROR: operator-sdk run bundle failed"
  exit 1
fi
echo ""

# 5. Wait for the controller pod to appear
echo "Waiting for GitOps controller pod to appear..."
for i in {0..30}; do
  sleep 3
  if oc get pod -n "${NAMESPACE}" | grep gitops > /dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: Controller pod did not appear after 90 seconds"
    oc get pods -n "${NAMESPACE}" -o wide || true
    exit 1
  fi
done

controller_pod=$(oc get pod -n "${NAMESPACE}" -l control-plane=gitops-operator -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$controller_pod" ]]; then
  echo "ERROR: Could not find controller pod with label control-plane=gitops-operator"
  oc get pods -n "${NAMESPACE}" -o wide || true
  exit 1
fi
echo "Controller pod: $controller_pod"
echo ""

# 6. Wait for openshift-gitops namespace to become Active
echo "Waiting for openshift-gitops namespace to become Active..."
if ! oc wait --for=jsonpath='{.status.phase}'=Active ns/openshift-gitops --timeout=120s; then
  echo "ERROR: openshift-gitops namespace did not become Active"
  oc get ns openshift-gitops -o yaml 2>/dev/null || echo "Namespace does not exist"
  exit 1
fi
echo ""

# 7. Wait for ArgoCD deployments to roll out
ARGOCD_NAMESPACE="openshift-gitops"
echo "Waiting for ArgoCD deployments in ${ARGOCD_NAMESPACE}..."

mapfile -t deployments < <(oc get deployments -n "${ARGOCD_NAMESPACE}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null)
if [[ ${#deployments[@]} -eq 0 ]]; then
  echo "ERROR: No deployments found in ${ARGOCD_NAMESPACE}"
  oc get all -n "${ARGOCD_NAMESPACE}" || true
  exit 1
fi

for deployment in "${deployments[@]}"; do
  echo "  Waiting for deployment/${deployment}..."
  if ! oc rollout status "deployment/${deployment}" -n "${ARGOCD_NAMESPACE}" --timeout=120s; then
    echo "ERROR: deployment/${deployment} did not roll out successfully"
    oc get deployment "${deployment}" -n "${ARGOCD_NAMESPACE}" -o wide || true
    oc get pods -n "${ARGOCD_NAMESPACE}" -o wide || true
    exit 1
  fi
done
echo ""

# 8. Wait for the application-controller StatefulSet
echo "Waiting for openshift-gitops-application-controller StatefulSet to be created..."
for i in {0..30}; do
  sleep 3
  if oc get statefulset -n "${ARGOCD_NAMESPACE}" | grep gitops > /dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: StatefulSet did not appear after 90 seconds"
    oc get statefulsets -n "${ARGOCD_NAMESPACE}" -o wide || true
    exit 1
  fi
done

echo "Waiting for statefulset rollout..."
if ! oc rollout status statefulset/openshift-gitops-application-controller -n "${ARGOCD_NAMESPACE}" --timeout=120s; then
  echo "ERROR: StatefulSet rollout failed"
  oc get statefulset openshift-gitops-application-controller -n "${ARGOCD_NAMESPACE}" -o wide || true
  oc get pods -n "${ARGOCD_NAMESPACE}" -o wide || true
  exit 1
fi
echo ""

# 9. Wait for ArgoCD CR to reach Available phase
echo "Waiting for ArgoCD CR to reach Available phase..."
if ! oc wait argocd openshift-gitops -n "${ARGOCD_NAMESPACE}" --for=jsonpath='{.status.phase}'="Available" --timeout=600s; then
  echo "ERROR: ArgoCD CR did not reach Available phase"
  oc get argocd openshift-gitops -n "${ARGOCD_NAMESPACE}" -o yaml || true
  exit 1
fi
echo ""

# 10. Output success and diagnostic information
echo "=========================================="
echo "✅ Bundle installation completed successfully!"
echo "=========================================="
echo ""

echo "--- Installed CSV ---"
oc get csv -n "${NAMESPACE}" -o wide || true
echo ""

echo "--- Operator Pods ---"
oc get pods -n "${NAMESPACE}" -o wide || true
echo ""

echo "--- ArgoCD Pods ---"
oc get pods -n "${ARGOCD_NAMESPACE}" -o wide || true
echo ""

echo "--- ArgoCD CR Status ---"
oc get argocd openshift-gitops -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status}' | python3 -m json.tool || true
echo ""

echo "--- ImageDigestMirrorSet ---"
oc get imagedigestmirrorset -o yaml 2>/dev/null || echo "No IDMS found"
echo ""

echo "=========================================="
