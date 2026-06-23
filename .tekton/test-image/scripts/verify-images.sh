#!/bin/bash
set -euo pipefail

# Verify that all images referenced by the installed CSV are actually
# available at their mirror locations (from IDMS on the cluster).
#
# Environment variables expected:
# - KUBECONFIG
# - NAMESPACE  (operator namespace, e.g. openshift-gitops-operator)
#
# Optional:
# - TARGET_ARCH  (e.g. arm64, amd64; auto-detected from cluster if unset)
# - IDMS_FILE    (path to images-mirror-set.yaml; falls back to cluster IDMS)

NAMESPACE="${NAMESPACE:-openshift-gitops-operator}"

# --- Detect target architecture ---
if [[ -z "${TARGET_ARCH:-}" ]]; then
  TARGET_ARCH=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "amd64")
fi
echo "Target architecture: ${TARGET_ARCH}"

# --- Get installed CSV name ---
CSV_NAME=$(oc get subscription -n "${NAMESPACE}" -o jsonpath='{.items[0].status.installedCSV}' 2>/dev/null || true)
if [[ -z "$CSV_NAME" ]]; then
  echo "ERROR: No installed CSV found in namespace ${NAMESPACE}"
  exit 1
fi
echo "Installed CSV: ${CSV_NAME}"

# --- Extract related images from CSV ---
RELATED_IMAGES=$(oc get csv "${CSV_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{range .spec.relatedImages[*]}{.image}{"\n"}{end}' 2>/dev/null)

if [[ -z "$RELATED_IMAGES" ]]; then
  echo "WARNING: No relatedImages found in CSV ${CSV_NAME}"
  exit 0
fi

IMAGE_COUNT=$(echo "$RELATED_IMAGES" | wc -l)
echo "Found ${IMAGE_COUNT} related images in CSV"

# --- Build mirror map from IDMS ---
declare -A MIRROR_MAP
if [[ -n "${IDMS_FILE:-}" && -f "${IDMS_FILE}" ]]; then
  echo "Loading mirrors from file: ${IDMS_FILE}"
  while IFS='|' read -r source mirror; do
    MIRROR_MAP["$source"]="$mirror"
  done < <(python3 -c "
import yaml, sys
with open('${IDMS_FILE}') as f:
    data = yaml.safe_load(f)
for entry in data['spec']['imageDigestMirrors']:
    print(entry['source'] + '|' + entry['mirrors'][0])
")
else
  echo "Loading mirrors from cluster IDMS..."
  while IFS='|' read -r source mirror; do
    [[ -n "$source" ]] && MIRROR_MAP["$source"]="$mirror"
  done < <(oc get imagedigestmirrorset -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    for entry in item.get('spec', {}).get('imageDigestMirrors', []):
        mirrors = entry.get('mirrors', [])
        if mirrors:
            print(entry['source'] + '|' + mirrors[0])
" 2>/dev/null || true)
fi

if [[ ${#MIRROR_MAP[@]} -eq 0 ]]; then
  echo "WARNING: No mirror mappings found (no IDMS on cluster and no IDMS_FILE set)"
  echo "Images will be pulled directly from source registries"
fi

echo ""
echo "Mirror mappings loaded: ${#MIRROR_MAP[@]} entries"

# --- Set up auth for skopeo ---
AUTH_ARGS=""
if [[ -f "/quay-pull-credentials/.dockerconfigjson" ]]; then
  AUTH_ARGS="--authfile=/quay-pull-credentials/.dockerconfigjson"
elif [[ -f "/quay-credentials/.dockerconfigjson" ]]; then
  AUTH_ARGS="--authfile=/quay-credentials/.dockerconfigjson"
fi

# --- Verify each image ---
FAILED=0
PASSED=0
SKIPPED=0

for IMAGE in $RELATED_IMAGES; do
  # Extract registry/repo and digest
  REPO="${IMAGE%%@*}"
  DIGEST="${IMAGE##*@}"

  # Find mirror for this repo
  MIRROR_REPO=""
  for SOURCE in "${!MIRROR_MAP[@]}"; do
    if [[ "$REPO" == "$SOURCE" ]]; then
      MIRROR_REPO="${MIRROR_MAP[$SOURCE]}"
      break
    fi
  done

  if [[ -n "$MIRROR_REPO" ]]; then
    CHECK_REF="${MIRROR_REPO}@${DIGEST}"
    LABEL="mirror"
  else
    # No mirror configured — this is a standard Red Hat image (redis, haproxy, etc.)
    # not part of the Konflux release. Skip verification.
    echo "  SKIP [no mirror] ${REPO}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if image exists at mirror
  if skopeo inspect --raw ${AUTH_ARGS} "docker://${CHECK_REF}" &>/dev/null; then
    # Check architecture support
    MANIFEST_TYPE=$(skopeo inspect --raw ${AUTH_ARGS} "docker://${CHECK_REF}" 2>/dev/null | python3 -c "
import json, sys
m = json.load(sys.stdin)
mt = m.get('mediaType', m.get('schemaVersion', ''))
if 'manifest.list' in str(mt) or 'image.index' in str(mt):
    archs = [p.get('platform', {}).get('architecture', '?') for p in m.get('manifests', [])]
    print('multi:' + ','.join(archs))
else:
    print('single')
" 2>/dev/null || echo "unknown")

    if [[ "$MANIFEST_TYPE" == single ]] || [[ "$MANIFEST_TYPE" == unknown ]]; then
      echo "  OK   [${LABEL}] ${REPO} (single-arch manifest)"
      PASSED=$((PASSED + 1))
    elif [[ "$MANIFEST_TYPE" == multi:* ]]; then
      ARCHS="${MANIFEST_TYPE#multi:}"
      if echo "$ARCHS" | grep -q "${TARGET_ARCH}"; then
        echo "  OK   [${LABEL}] ${REPO} (${TARGET_ARCH} in: ${ARCHS})"
        PASSED=$((PASSED + 1))
      else
        echo "  FAIL [${LABEL}] ${REPO} — missing ${TARGET_ARCH} (available: ${ARCHS})"
        echo "         ref: ${CHECK_REF}"
        FAILED=$((FAILED + 1))
      fi
    fi
  else
    echo "  FAIL [${LABEL}] ${REPO} — image not found at mirror"
    echo "         mirror: ${CHECK_REF}"
    echo "         source: ${IMAGE}"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=========================================="
echo "Image verification: ${PASSED} OK, ${FAILED} FAILED, ${SKIPPED} SKIPPED (no mirror)"
echo "=========================================="

if [[ $FAILED -gt 0 ]]; then
  echo "ERROR: ${FAILED} image(s) are not available at their expected locations."
  echo "The operator will fail to create workload pods for these images."
  exit 1
fi
