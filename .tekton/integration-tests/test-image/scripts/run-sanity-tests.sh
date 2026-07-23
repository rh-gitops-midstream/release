#!/bin/bash
set -euo pipefail

# Release sanity checks for the gitops-operator (replaces manual GITOPS-6448 checklist).
# Validates: CSV health, operator pods, toolchain versions, basic app sync.
#
# Env vars expected:
#   KUBECONFIG - path to cluster kubeconfig
# Env vars optional:
#   NAMESPACE            - operator namespace (default: openshift-gitops-operator)
#   GITOPS_NS            - ArgoCD instance namespace (default: openshift-gitops)
#   CONFLUENCE_USERNAME  - Confluence API username (for component matrix lookup)
#   CONFLUENCE_TOKEN     - Confluence API token
#   CONFLUENCE_PAGE_ID   - Component matrix page ID (default: 265652015)

# shellcheck source=./lib/wait-for-resources.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wait-for-resources.sh"

RESULTS_DIR="${RESULTS_DIR:-/tmp/task-logs}"
mkdir -p "${RESULTS_DIR}"

NAMESPACE="${NAMESPACE:-openshift-gitops-operator}"
GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
if [[ -z "${CONFLUENCE_USERNAME:-}" && -f /confluence-credentials/username ]]; then
  CONFLUENCE_USERNAME=$(cat /confluence-credentials/username)
fi
if [[ -z "${CONFLUENCE_TOKEN:-}" && -f /confluence-credentials/token ]]; then
  CONFLUENCE_TOKEN=$(cat /confluence-credentials/token)
fi
CONFLUENCE_USERNAME="${CONFLUENCE_USERNAME:-}"
CONFLUENCE_TOKEN="${CONFLUENCE_TOKEN:-}"
CONFLUENCE_PAGE_ID="${CONFLUENCE_PAGE_ID:-265652015}"

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "PASS: $1"; }

# --- Fetch expected versions from Confluence Component Matrix ---
fetch_expected_versions() {
  if [[ -z "${CONFLUENCE_USERNAME}" || -z "${CONFLUENCE_TOKEN}" ]]; then
    echo "Confluence credentials not configured, skipping version assertions"
    return 1
  fi

  local page_url="https://redhat.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}?expand=body.storage"
  local body
  body=$(curl -sf -u "${CONFLUENCE_USERNAME}:${CONFLUENCE_TOKEN}" \
    --url "${page_url}" --header "Accept: application/json" 2>/dev/null || true)

  if [[ -z "$body" ]]; then
    echo "WARNING: Could not fetch Component Matrix from Confluence"
    return 1
  fi

  # Extract installed operator version to look up in the matrix
  local operator_version
  operator_version=$(echo "${CSV_NAME:-}" | grep -oP '\d+\.\d+\.\d+' || true)
  if [[ -z "$operator_version" ]]; then
    echo "WARNING: Could not determine operator version from CSV name '${CSV_NAME:-}'"
    return 1
  fi

  echo "Looking up expected versions for operator ${operator_version} in Component Matrix..."

  # Parse the HTML table and extract versions for our operator version
  # Columns: 0=Version, 5=Helm, 6=Kustomize, 8=ArgoCD, 15=Dex
  local parsed
  parsed=$(echo "$body" | python3 -c "
import json, sys, re
from html.parser import HTMLParser

target = '${operator_version}'

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_t = self.in_r = self.in_c = False
        self.rows, self.row, self.cell = [], [], ''
    def handle_starttag(self, t, a):
        if t == 'table': self.in_t = True
        elif t == 'tr' and self.in_t: self.in_r = True; self.row = []
        elif t in ('td','th') and self.in_r: self.in_c = True; self.cell = ''
    def handle_endtag(self, t):
        if t in ('td','th') and self.in_c: self.in_c = False; self.row.append(self.cell.strip())
        elif t == 'tr' and self.in_r: self.in_r = False; self.rows.append(self.row) if self.row else None
        elif t == 'table': self.in_t = False
    def handle_data(self, d):
        if self.in_c: self.cell += d

p = P()
d = json.load(sys.stdin)
p.feed(d['body']['storage']['value'])
for r in p.rows:
    if len(r) >= 16 and r[0] == target:
        print(f'HELM={r[5]}')
        print(f'KUSTOMIZE={r[6]}')
        print(f'ARGOCD={r[8]}')
        print(f'DEX={r[15]}')
        break
" 2>/dev/null || true)

  if [[ -z "$parsed" ]]; then
    echo "WARNING: Operator version ${operator_version} not found in Component Matrix"
    return 1
  fi

  EXPECTED_HELM="" EXPECTED_KUSTOMIZE="" EXPECTED_ARGOCD="" EXPECTED_DEX=""
  while IFS='=' read -r key val; do
    # Only accept known keys with safe values
    val="${val//[^a-zA-Z0-9._-]/}"
    case "$key" in
      HELM)      EXPECTED_HELM="$val" ;;
      KUSTOMIZE) EXPECTED_KUSTOMIZE="$val" ;;
      ARGOCD)    EXPECTED_ARGOCD="$val" ;;
      DEX)       EXPECTED_DEX="$val" ;;
    esac
  done <<< "$parsed"
  echo "  Expected Helm:      ${EXPECTED_HELM}"
  echo "  Expected Kustomize: ${EXPECTED_KUSTOMIZE}"
  echo "  Expected ArgoCD:    ${EXPECTED_ARGOCD}"
  echo "  Expected Dex:       ${EXPECTED_DEX}"
  return 0
}

EXPECTED_HELM="" EXPECTED_KUSTOMIZE="" EXPECTED_ARGOCD="" EXPECTED_DEX=""
HAS_EXPECTED=false

# ============================================================
# 1. Bundle / CSV validation
# ============================================================
echo ""
echo "=========================================="
echo "1. Bundle / CSV Validation"
echo "=========================================="

CSV_NAME=$(oc get csv -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$CSV_NAME" ]]; then
  fail "No ClusterServiceVersion found in ${NAMESPACE}"
else
  echo "Installed CSV: ${CSV_NAME}"

  CSV_PHASE=$(oc get csv "${CSV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$CSV_PHASE" == "Succeeded" ]]; then
    pass "CSV phase is Succeeded"
  else
    fail "CSV phase is '${CSV_PHASE}', expected 'Succeeded'"
  fi

  RELATED_COUNT=$(oc get csv "${CSV_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.relatedImages}' 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [[ "$RELATED_COUNT" -gt 0 ]]; then
    pass "CSV has ${RELATED_COUNT} relatedImages"
    echo "  Related images:"
    oc get csv "${CSV_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{range .spec.relatedImages[*]}  - {.name}: {.image}{"\n"}{end}' 2>/dev/null || true
  else
    fail "CSV has no relatedImages"
  fi
fi

if fetch_expected_versions; then
  HAS_EXPECTED=true
fi

# ============================================================
# 2. Operator health check
# ============================================================
echo ""
echo "=========================================="
echo "2. Operator Health Check"
echo "=========================================="

for deploy in openshift-gitops-server openshift-gitops-repo-server \
              openshift-gitops-applicationset-controller openshift-gitops-redis; do
  if oc get deployment "${deploy}" -n "${GITOPS_NS}" &>/dev/null; then
    if wait_for_deployment "${deploy}" "${GITOPS_NS}" 60s; then
      pass "Deployment ${deploy} is Available"
    else
      fail "Deployment ${deploy} is NOT Available"
    fi
  else
    fail "Deployment ${deploy} not found in ${GITOPS_NS}"
  fi
done

CONTROLLER="openshift-gitops-application-controller"
if oc get statefulset "${CONTROLLER}" -n "${GITOPS_NS}" &>/dev/null; then
  if wait_for_statefulset "${CONTROLLER}" "${GITOPS_NS}" 60s; then
    pass "StatefulSet ${CONTROLLER} is ready"
  else
    fail "StatefulSet ${CONTROLLER} is NOT ready"
  fi
else
  fail "StatefulSet ${CONTROLLER} not found in ${GITOPS_NS}"
fi

BAD_PODS=$(oc get pods -n "${GITOPS_NS}" --no-headers 2>/dev/null \
  | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error' || true)
if [[ -z "$BAD_PODS" ]]; then
  pass "No pods in error state"
else
  fail "Pods in error state:"
  echo "$BAD_PODS"
fi

# ============================================================
# 3. Toolchain version report
# ============================================================
echo ""
echo "=========================================="
echo "3. Toolchain Version Report"
echo "=========================================="

SERVER_POD=$(oc get pods -n "${GITOPS_NS}" --no-headers \
  -l app.kubernetes.io/name=openshift-gitops-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DEX_POD=$(oc get pods -n "${GITOPS_NS}" --no-headers \
  -l app.kubernetes.io/name=openshift-gitops-dex-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
REDIS_POD=$(oc get pods -n "${GITOPS_NS}" --no-headers \
  -l app.kubernetes.io/name=openshift-gitops-redis \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

declare -A versions

if [[ -n "$SERVER_POD" ]]; then
  versions[kustomize]=$(oc exec -n "${GITOPS_NS}" "${SERVER_POD}" -- kustomize version 2>/dev/null || echo "N/A")
  versions[helm]=$(oc exec -n "${GITOPS_NS}" "${SERVER_POD}" -- helm version --short 2>/dev/null \
    | sed 's/+.*//' || echo "N/A")
  versions[argocd]=$(oc exec -n "${GITOPS_NS}" "${SERVER_POD}" -- argocd version --client --short 2>/dev/null \
    | grep -oP 'v[\d.]+' | head -1 || echo "N/A")
else
  echo "WARNING: argocd-server pod not found, skipping kustomize/helm/argocd version checks"
  versions[kustomize]="N/A"; versions[helm]="N/A"; versions[argocd]="N/A"
fi

if [[ -n "$DEX_POD" ]]; then
  versions[dex]=$(oc exec -n "${GITOPS_NS}" "${DEX_POD}" -- dex version 2>&1 \
    | grep -i 'version' | head -1 | awk -F': ' '{print $2}' || echo "N/A")
else
  echo "WARNING: dex pod not found"
  versions[dex]="N/A"
fi

if [[ -n "$REDIS_POD" ]]; then
  versions[redis]=$(oc exec -n "${GITOPS_NS}" "${REDIS_POD}" -- redis-server -v 2>/dev/null \
    | awk -F'=' '{print $2}' | cut -d' ' -f1 || echo "N/A")
else
  echo "WARNING: redis pod not found"
  versions[redis]="N/A"
fi

echo ""
echo "  Component versions:"
for component in kustomize helm argocd dex redis; do
  printf "    %-12s %s\n" "${component}:" "${versions[$component]}"
done

# Assert versions against Component Matrix if available
if [[ "$HAS_EXPECTED" == "true" ]]; then
  echo ""
  echo "  Checking against Component Matrix:"
  check_version() {
    local name=$1 actual=$2 expected=$3
    if [[ -z "$expected" ]]; then
      return
    fi
    # Strip leading 'v' for comparison
    local actual_clean="${actual#v}"
    local expected_clean="${expected#v}"
    if [[ "$actual_clean" == "$expected_clean" ]]; then
      pass "${name} version matches (${actual})"
    else
      fail "${name} version mismatch: deployed=${actual}, expected=${expected}"
    fi
  }
  check_version "Helm" "${versions[helm]}" "${EXPECTED_HELM}"
  check_version "Kustomize" "${versions[kustomize]}" "${EXPECTED_KUSTOMIZE}"
  check_version "ArgoCD" "${versions[argocd]}" "${EXPECTED_ARGOCD}"
  check_version "Dex" "${versions[dex]}" "${EXPECTED_DEX}"
else
  echo "  (No expected versions available — report only, no assertions)"
fi

# ============================================================
# 4. ArgoCD login test
# ============================================================
echo ""
echo "=========================================="
echo "4. ArgoCD Login Test"
echo "=========================================="

ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n "${GITOPS_NS}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
ARGOCD_PASSWORD=$(oc get secret openshift-gitops-cluster -n "${GITOPS_NS}" \
  -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -z "$ARGOCD_ROUTE" ]]; then
  fail "ArgoCD route not found in ${GITOPS_NS}"
elif [[ -z "$ARGOCD_PASSWORD" ]]; then
  fail "ArgoCD admin password not found"
else
  echo "ArgoCD URL: https://${ARGOCD_ROUTE}"

  LOGIN_RESPONSE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "https://${ARGOCD_ROUTE}/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${ARGOCD_PASSWORD}\"}" 2>/dev/null || echo "000")

  if [[ "$LOGIN_RESPONSE" == "200" ]]; then
    pass "ArgoCD admin login via API succeeded (HTTP 200)"
  else
    fail "ArgoCD admin login failed (HTTP ${LOGIN_RESPONSE})"
  fi

  # Test OpenShift SSO endpoint is reachable
  DEX_RESPONSE=$(curl -sk -o /dev/null -w "%{http_code}" \
    "https://${ARGOCD_ROUTE}/api/dex/.well-known/openid-configuration" 2>/dev/null || echo "000")

  if [[ "$DEX_RESPONSE" == "200" ]]; then
    pass "Dex/SSO OpenID configuration endpoint reachable (HTTP 200)"
  else
    fail "Dex/SSO OpenID configuration endpoint not reachable (HTTP ${DEX_RESPONSE})"
  fi
fi

# ============================================================
# 5. App sync smoke test
# ============================================================
echo ""
echo "=========================================="
echo "5. App Sync Smoke Test"
echo "=========================================="

TEST_APP_NS="sanity-test-smoke"
TEST_APP_NAME="sanity-smoke"
TEST_APP_REPO="${CATALOG_URL:-https://github.com/rh-gitops-midstream/catalog.git}"
TEST_APP_REVISION="${CATALOG_REVISION:-HEAD}"
TEST_APP_PATH=".tekton/test-image/config/smoke-app"

cleanup_smoke_test() {
  oc delete application "${TEST_APP_NAME}" -n "${GITOPS_NS}" --ignore-not-found 2>/dev/null || true
  oc delete namespace "${TEST_APP_NS}" --ignore-not-found 2>/dev/null || true
}
trap cleanup_smoke_test EXIT

oc create namespace "${TEST_APP_NS}" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc label namespace "${TEST_APP_NS}" "argocd.argoproj.io/managed-by=${GITOPS_NS}" --overwrite

echo "Waiting for operator to create RBAC in ${TEST_APP_NS}..."
for _rbac_wait in $(seq 1 30); do
  if oc get rolebinding -n "${TEST_APP_NS}" 2>/dev/null | grep -q "${GITOPS_NS}"; then
    echo "RBAC ready in ${TEST_APP_NS}"
    break
  fi
  sleep 2
done

cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${TEST_APP_NAME}
  namespace: ${GITOPS_NS}
spec:
  project: default
  source:
    repoURL: ${TEST_APP_REPO}
    targetRevision: ${TEST_APP_REVISION}
    path: ${TEST_APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${TEST_APP_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo "Waiting for app sync..."
SYNC_OK=false
for _attempt in $(seq 1 60); do
  SYNC_STATUS=$(oc get application "${TEST_APP_NAME}" -n "${GITOPS_NS}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  HEALTH_STATUS=$(oc get application "${TEST_APP_NAME}" -n "${GITOPS_NS}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)

  if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" ]]; then
    SYNC_OK=true
    break
  fi
  sleep 5
done

if [[ "$SYNC_OK" == "true" ]]; then
  pass "Smoke app synced and healthy"
else
  fail "Smoke app did not reach Synced/Healthy (sync=${SYNC_STATUS:-unknown}, health=${HEALTH_STATUS:-unknown})"
  oc get application "${TEST_APP_NAME}" -n "${GITOPS_NS}" -o yaml 2>/dev/null || true
fi

cleanup_smoke_test
trap - EXIT

# ============================================================
# Summary
# ============================================================
echo ""
echo "=========================================="
echo "Sanity Test Summary"
echo "=========================================="

CSV_NAME_VAL="${CSV_NAME:-unknown}" \
CSV_PHASE_VAL="${CSV_PHASE:-unknown}" \
RELATED_COUNT_VAL="${RELATED_COUNT:-0}" \
VERSION_KUSTOMIZE="${versions[kustomize]}" \
VERSION_HELM="${versions[helm]}" \
VERSION_ARGOCD="${versions[argocd]}" \
VERSION_DEX="${versions[dex]}" \
VERSION_REDIS="${versions[redis]}" \
LOGIN_RESPONSE_VAL="${LOGIN_RESPONSE:-untested}" \
DEX_RESPONSE_VAL="${DEX_RESPONSE:-untested}" \
SYNC_OK_VAL="${SYNC_OK}" \
FAILURES_VAL="${failures}" \
python3 -c "
import json, os
data = {
    'csv': os.environ['CSV_NAME_VAL'],
    'csvPhase': os.environ['CSV_PHASE_VAL'],
    'relatedImages': int(os.environ['RELATED_COUNT_VAL']),
    'versions': {
        'kustomize': os.environ['VERSION_KUSTOMIZE'],
        'helm':      os.environ['VERSION_HELM'],
        'argocd':    os.environ['VERSION_ARGOCD'],
        'dex':       os.environ['VERSION_DEX'],
        'redis':     os.environ['VERSION_REDIS'],
    },
    'loginApi':    os.environ['LOGIN_RESPONSE_VAL'],
    'dexEndpoint': os.environ['DEX_RESPONSE_VAL'],
    'appSyncSmoke': os.environ['SYNC_OK_VAL'] == 'true',
    'failures':    int(os.environ['FAILURES_VAL']),
}
print(json.dumps(data, indent=2))
" > "${RESULTS_DIR}/sanity-results.json"

if [[ "$failures" -eq 0 ]]; then
  echo "All sanity checks PASSED"
  exit 0
else
  echo "${failures} sanity check(s) FAILED"
  exit 1
fi
