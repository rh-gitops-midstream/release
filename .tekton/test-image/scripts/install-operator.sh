#!/bin/bash
set -ex

# Environment variables expected:
# - OPENSHIFT_VERSION (e.g. "4.20" or "4.20.19")
# - NAMESPACE
# - INSTALL_TIMEOUT
# - KUBECONFIG

MINOR_VERSION=$(echo "${OPENSHIFT_VERSION}" | grep -oP '^\d+\.\d+')
CATALOG_IMAGE="quay.io/redhat-user-workloads/rh-openshift-gitops-tenant/catalog:v${MINOR_VERSION}"

echo "Installing GitOps Operator from catalog: ${CATALOG_IMAGE}"
echo "OpenShift version: ${OPENSHIFT_VERSION} (minor: ${MINOR_VERSION})"
echo "Target namespace: ${NAMESPACE}"

# 1. Inject quay pull credentials into cluster
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  # 1a. Patch global pull-secret (may take time to propagate on HyperShift)
  echo "Injecting quay pull credentials into cluster global pull-secret..."
  EXISTING=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  MERGED=$(echo "$EXISTING" | python3 -c "
import json, sys
existing = json.load(sys.stdin)
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    extra = json.load(f)
existing.setdefault('auths', {}).update(extra.get('auths', {}))
print(json.dumps(existing))
")
  oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$MERGED"
  echo "Injected $(echo "$MERGED" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['auths']))" 2>/dev/null) registry credentials into cluster pull-secret"

  # 1b. Create additional-pull-secret in kube-system (HyperShift-native mechanism).
  # The Hosted Cluster Config Operator detects this secret and deploys a DaemonSet
  # that writes credentials to /var/lib/kubelet/config.json on each node.
  echo "Creating additional-pull-secret in kube-system for HyperShift node credential injection..."
  oc create secret generic additional-pull-secret \
    -n kube-system \
    --from-file=.dockerconfigjson=/quay-pull-credentials/.dockerconfigjson \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -

  # Wait for the syncer DaemonSet to appear and propagate to all nodes
  echo "Waiting for pull-secret syncer DaemonSet..."
  SYNC_TIMEOUT=300
  SYNC_START=$(date +%s)
  while true; do
    DS_NAME=$(oc get daemonset -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -i 'pull-secret' || true)

    if [[ -n "$DS_NAME" ]]; then
      DESIRED=$(oc get ds "$DS_NAME" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
      READY=$(oc get ds "$DS_NAME" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
      if [[ "$DESIRED" -gt 0 && "$DESIRED" == "$READY" ]]; then
        echo "Pull-secret syncer DaemonSet $DS_NAME is ready ($READY/$DESIRED nodes)"
        break
      fi
      echo "  Syncer DaemonSet $DS_NAME: $READY/$DESIRED nodes ready..."
    fi

    ELAPSED=$(( $(date +%s) - SYNC_START ))
    if [[ $ELAPSED -ge $SYNC_TIMEOUT ]]; then
      echo "WARNING: Pull-secret syncer not fully ready within ${SYNC_TIMEOUT}s, continuing anyway"
      oc get daemonset -n kube-system 2>/dev/null || true
      break
    fi
    sleep 15
  done
else
  echo "WARNING: No quay pull credentials found at /quay-pull-credentials/.dockerconfigjson"
fi

# 2. Ensure the operator namespace exists
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# 3. Create CatalogSource
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: gitops-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CATALOG_IMAGE}
  displayName: GitOps Stage Catalog
  publisher: Konflux
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

# 4. Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: gitops-operator-group
  namespace: ${NAMESPACE}
spec: {}
EOF

# 5. Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gitops-operator-konflux
  namespace: ${NAMESPACE}
spec:
  channel: latest
  name: openshift-gitops-operator
  source: gitops-stage
  sourceNamespace: openshift-marketplace
EOF

# 6. Wait for installation
echo "Waiting for ClusterServiceVersion to appear and succeed..."
sleep 30

CSV_NAME=""
for _ in {1..30}; do
  CSV_NAME=$(oc get sub gitops-operator-konflux -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' || true)
  if [ -n "$CSV_NAME" ]; then break; fi
  echo "Waiting for subscription status to be updated..."
  sleep 10
done

if [ -z "$CSV_NAME" ]; then
  echo "Error: CSV name not found in subscription"
  oc get sub gitops-operator-konflux -n "${NAMESPACE}" -o yaml
  exit 1
fi

oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${CSV_NAME}" -n "${NAMESPACE}" --timeout="${INSTALL_TIMEOUT}"

echo "Operator installed successfully"

# 7. Fallback: inject pull credentials into openshift-gitops namespace
# In case the additional-pull-secret DaemonSet (step 1b) hasn't fully propagated
# by the time ArgoCD pods start, this background loop links a namespace-scoped
# pull secret to service accounts and restarts stuck pods.
SA_PATCH_PID=""
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  echo ""
  echo "=========================================="
  echo "Starting background pull-secret injection"
  echo "=========================================="
  (
    while true; do
      if oc get namespace openshift-gitops &>/dev/null; then
        # Ensure pull secret exists in the namespace
        oc create secret generic quay-mirror-pull \
          --from-file=.dockerconfigjson=/quay-pull-credentials/.dockerconfigjson \
          --type=kubernetes.io/dockerconfigjson \
          -n openshift-gitops \
          --dry-run=client -o yaml | oc apply -f - &>/dev/null

        # Link to all SAs that don't already have it
        for sa in $(oc get sa -n openshift-gitops -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          if ! oc get sa "$sa" -n openshift-gitops -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null | grep -q quay-mirror-pull; then
            oc patch sa "$sa" -n openshift-gitops --type=json \
              -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"quay-mirror-pull"}}]' &>/dev/null || true
          fi
        done

        # Restart pods stuck on image pull errors so they pick up the new SA credentials
        STUCK=$(oc get pods -n openshift-gitops 2>/dev/null | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}')
        for pod in $STUCK; do
          echo "  [pull-secret-injector] Restarting stuck pod: $pod"
          oc delete pod "$pod" -n openshift-gitops --grace-period=0 &>/dev/null || true
        done
      fi
      sleep 10
    done
  ) &
  SA_PATCH_PID=$!
  echo "Background pull-secret injection started (PID: $SA_PATCH_PID)"
fi

# 8. Verify all related images are available at mirrors
echo ""
echo "=========================================="
echo "Verifying related images are available"
echo "=========================================="
/usr/local/bin/verify-images.sh || {
  echo "WARNING: Some images are not available at their mirror locations."
  echo "ArgoCD pods may fail with ImagePullBackOff."
}

echo ""
echo "=========================================="
echo "DEBUG INFO: Post-Installation State"
echo "=========================================="
echo ""

echo "--- CatalogSource Status ---"
oc get catalogsource gitops-stage -n openshift-marketplace -o yaml || true
echo ""

echo "--- Subscription Status ---"
oc get subscription gitops-operator-konflux -n "${NAMESPACE}" -o yaml || true
echo ""

echo "--- ClusterServiceVersion Status ---"
oc get csv "${CSV_NAME}" -n "${NAMESPACE}" -o yaml || true
echo ""

echo "--- All Pods in ${NAMESPACE} ---"
oc get pods -n "${NAMESPACE}" -o wide || true
echo ""

echo "--- Events in ${NAMESPACE} ---"
oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' || true
echo ""

echo "--- Operator Deployment ---"
oc get deployments -n "${NAMESPACE}" -o wide || true
echo ""

echo "=========================================="

# 9. Verify default ArgoCD instance is ready
echo ""
echo "=========================================="
echo "Verifying default ArgoCD instance"
echo "=========================================="

echo "Waiting for openshift-gitops namespace and ArgoCD deployments to appear..."
for _ in {1..60}; do
  if oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
    break
  fi
  sleep 10
done

if ! oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
  echo "ERROR: ArgoCD deployments not created after 10 minutes"
  oc get ns openshift-gitops 2>/dev/null || echo "Namespace openshift-gitops does not exist"
  oc get argocd -n openshift-gitops 2>/dev/null || true
  oc get pods -n openshift-gitops -o wide 2>/dev/null || true
  oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
  echo "--- IDMS on cluster ---"
  oc get imagedigestmirrorset 2>/dev/null || echo "No IDMS"
  echo "--- Operator logs ---"
  oc logs deployment/openshift-gitops-operator-controller-manager -n openshift-gitops-operator -c manager --tail=50 2>/dev/null || true
  exit 1
fi

echo "ArgoCD deployments found, waiting for them to become available..."
for deploy in openshift-gitops-server openshift-gitops-repo-server; do
  if ! oc wait --for=condition=Available "deployment/$deploy" -n openshift-gitops --timeout=600s; then
    echo "ERROR: deployment/$deploy did not become Available"
    oc get deployment "$deploy" -n openshift-gitops -o wide 2>/dev/null || true
    oc get pods -n openshift-gitops -o wide 2>/dev/null || true
    echo "--- Pod details ---"
    for pod in $(oc get pods -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      echo "=== $pod ==="
      oc get pod "$pod" -n openshift-gitops -o jsonpath='{range .status.containerStatuses[*]}container={.name} ready={.ready} state={.state}{"\n"}{end}' 2>/dev/null || true
    done
    echo "--- Events ---"
    oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    echo "--- IDMS ---"
    oc get imagedigestmirrorset 2>/dev/null || echo "No IDMS"
    exit 1
  fi
  echo "$deploy is ready"
done

# application-controller is a StatefulSet, not a Deployment
if oc get statefulset openshift-gitops-application-controller -n openshift-gitops &>/dev/null; then
  if ! oc rollout status statefulset/openshift-gitops-application-controller -n openshift-gitops --timeout=600s; then
    echo "ERROR: statefulset/openshift-gitops-application-controller did not become ready"
    oc get pods -n openshift-gitops -o wide 2>/dev/null || true
    oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    exit 1
  fi
  echo "openshift-gitops-application-controller is ready"
else
  echo "WARNING: openshift-gitops-application-controller statefulset not found, skipping"
fi

echo "ArgoCD instance is ready"

# Stop background pull-secret injection
if [[ -n "${SA_PATCH_PID}" ]]; then
  kill $SA_PATCH_PID 2>/dev/null || true
  wait $SA_PATCH_PID 2>/dev/null || true
  echo "Stopped background pull-secret injection"
fi

# 10. Collect cluster-wide debug info (on success)
echo ""
echo "=========================================="
echo "DEBUG INFO: Cluster Image Configuration"
echo "=========================================="

echo "--- ImageDigestMirrorSet ---"
oc get imagedigestmirrorset -o yaml 2>/dev/null || echo "No IDMS found"
echo ""

echo "--- ImageContentSourcePolicy ---"
oc get imagecontentsourcepolicy -o yaml 2>/dev/null || echo "No ICSP found"
echo ""

echo "--- openshift-gitops namespace pods ---"
oc get pods -n openshift-gitops -o wide 2>/dev/null || true
echo ""

echo "--- openshift-gitops namespace events (last 5 min) ---"
oc get events -n openshift-gitops --sort-by='.lastTimestamp' 2>/dev/null | tail -40 || true
echo ""

echo "--- openshift-gitops pod descriptions (non-Running) ---"
for pod in $(oc get pods -n openshift-gitops -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  echo "=== Pod: $pod ==="
  oc describe pod "$pod" -n openshift-gitops 2>/dev/null | grep -A5 -E 'State:|Image:|Warning|Error|Back-off|ImagePull' || true
  echo ""
done

echo "=========================================="

# 11. Verify pull-secret propagated to nodes
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  echo ""
  echo "=========================================="
  echo "Verifying pull-secret propagation to nodes"
  echo "=========================================="
  EXPECTED_REPOS=$(python3 -c "
import json
with open('/quay-pull-credentials/.dockerconfigjson') as f:
    d = json.load(f)
for k in sorted(d.get('auths', {})):
    print(k)
" 2>/dev/null | head -3)
  CLUSTER_SECRET=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d)
  MISSING=0
  while IFS= read -r repo; do
    if echo "$CLUSTER_SECRET" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$repo' in d.get('auths',{}) else 1)" 2>/dev/null; then
      echo "  OK   $repo"
    else
      echo "  MISS $repo"
      MISSING=$((MISSING + 1))
    fi
  done <<< "$EXPECTED_REPOS"
  if [[ $MISSING -gt 0 ]]; then
    echo "WARNING: $MISSING repo(s) missing from cluster pull-secret"
  else
    echo "Pull-secret contains injected credentials"
  fi
fi
