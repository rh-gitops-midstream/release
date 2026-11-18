#!/bin/bash
# Regenerate helm-charts/openshift-gitops-operator from an operator bundle image.
#
# Usage: hack/update-helm-chart.sh <bundle-image>
#        hack/update-helm-chart.sh --check-flags
#   --check-flags only verifies kubectl-catalog has every flag used below;
#   CI runs it at install time so a bad pin fails before the bundle wait.
#   Reads config.yaml (release.version, release.olm.channel) from the repo root.
#   PULL_SECRET overrides the registry auth file (default ~/.docker/config.json).
#
# Single chart: CRDs ship in the chart's crds/. The separate
# openshift-gitops-operator-crds chart is not touched.
#
# Requires: kubectl-catalog, yq (v4), helm.
set -euo pipefail

cd "$(dirname "$0")/.."

CHART_DIR="helm-charts/openshift-gitops-operator"
CHART_YAML="${CHART_DIR}/Chart.yaml"

# GNU and BSD sed disagree on `-i`; a backup suffix works on both.
# Usage: sed_i <file> <sed-expression>
sed_i() { sed -i.bak "$2" "$1" && rm -f "$1.bak"; }

check_flags() {
  # Capture help first: piping into `grep -q` under pipefail SIGPIPEs
  # kubectl-catalog on early match and reports a false "has no flag".
  local help flag
  help=$(kubectl-catalog generate --help)
  for flag in --bundle --output-format --chart-name --env --pull-secret --output; do
    # Word boundary: plain substring would let --output match --output-format.
    grep -qE -- "${flag}([^-[:alnum:]_]|$)" <<<"${help}" || {
      echo "kubectl-catalog has no ${flag}"
      exit 1
    }
  done
}

if [[ "${1:-}" == "--check-flags" ]]; then
  check_flags
  echo "kubectl-catalog has all required flags."
  exit 0
fi

BUNDLE_IMAGE="${1:?usage: $0 <bundle-image> | --check-flags}"
PULL_SECRET="${PULL_SECRET:-$HOME/.docker/config.json}"
[[ -r "${PULL_SECRET}" ]] || {
  echo "Pull secret file '${PULL_SECRET}' not found or unreadable (set PULL_SECRET)."
  exit 1
}

# An empty tag ("...bundle:") makes kubectl-catalog fall back to `latest` and
# report a misleading 404 "authentication failed".
if [[ ! "${BUNDLE_IMAGE}" =~ (:[^/:]+|@sha256:[0-9a-f]+)$ ]]; then
  echo "Bundle image '${BUNDLE_IMAGE}' has no tag or digest."
  exit 1
fi

# ── Preflight: everything that can fail before the chart is touched ──
check_flags

# Same source the workflow uses for the bundle tag (v<release.version>), so
# chart version and bundle cannot disagree.
VERSION=$(yq -r '.release.version' config.yaml)
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected release.version '${VERSION}' in config.yaml"
  exit 1
fi

# In --bundle mode kubectl-catalog emits empty channel/catalog-ref
# annotations, so the committed Chart.yaml is kept and patched:
#  - channel from config.yaml (same source as hack/generate-catalog.py),
#    dropping the floating "latest" entry the chart doesn't track
#  - catalog-ref is not carried (no catalog in --bundle mode)
CHANNEL=$(yq -r '.release.olm.channel' config.yaml \
  | tr ',' '\n' | tr -d ' "' | grep -vx 'latest' | head -1 || true)
if [[ -z "${CHANNEL}" || "${CHANNEL}" == "null" ]]; then
  echo "Could not determine channel from config.yaml (.release.olm.channel)"
  exit 1
fi

# CHANNEL is spliced into a sed expression below; keep it to safe characters.
if [[ ! "${CHANNEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Unexpected channel '${CHANNEL}' in config.yaml (.release.olm.channel)"
  exit 1
fi

# sed only rewrites lines that already exist - a missing key would be a
# silent no-op, so require each one up front.
for KEY in '^version:' '^appVersion:' 'kubectl-catalog.io/channel:'; do
  grep -q "${KEY}" "${CHART_YAML}" || {
    echo "${CHART_YAML} has no line matching '${KEY}'; refusing to update it silently."
    exit 1
  }
done

# ── Generate ─────────────────────────────────────────────────────────
OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT

# The positional arg is the OLM package name; the bundle goes in --bundle.
# --bundle is mutually exclusive with --channel/--catalog/--ocp-version.
# --env bakes ENABLE_CONVERSION_WEBHOOK=false in as the template default.
kubectl-catalog generate openshift-gitops-operator \
  --bundle "${BUNDLE_IMAGE}" \
  --output-format helm \
  --chart-name openshift-gitops-operator \
  --env "ENABLE_CONVERSION_WEBHOOK=false" \
  --pull-secret "${PULL_SECRET}" \
  --output "${OUT}"

echo "kubectl-catalog output:"
find "${OUT}" -type f | sort

# Non-empty, not merely present: an empty crds/ or templates/ would wipe
# the chart on copy and still satisfy `helm lint`.
for REQUIRED in crds templates; do
  find "${OUT}/${REQUIRED}" -type f -name '*.yaml' 2>/dev/null | grep -q . || {
    echo "kubectl-catalog produced no manifests in ${REQUIRED}/; aborting before touching the chart."
    exit 1
  }
done
[[ -s "${OUT}/values.yaml" ]] || {
  echo "kubectl-catalog produced no values.yaml; aborting before touching the chart."
  exit 1
}

# Patch the generated output in the temp dir, so a failing edit leaves
# the committed chart untouched.

# GitopsService CRD is not shipped.
rm -f "${OUT}"/crds/gitopsservices*.yaml

# ArgoCD CRD: drop the conversion webhook (no webhook service backs it in
# this chart) and the deprecated v1alpha1 version it would convert.
ARGOCD_CRD="${OUT}/crds/argocds.argoproj.io.yaml"
yq -i 'del(.spec.conversion)' "${ARGOCD_CRD}"
yq -i 'del(.spec.versions[] | select(.name == "v1alpha1"))' "${ARGOCD_CRD}"

# GitopsService CRD is dropped from crds/; drop it from NOTES too.
sed_i "${OUT}/templates/NOTES.txt" '/- gitopsservices\.pipelines\.openshift\.io/d'

# ── Stage the chart ──────────────────────────────────────────────────
# Build and validate the whole new chart in the temp dir; the committed chart
# is only touched after everything passed, so a failure leaves it intact.
# templates/ is generated wholesale (_helpers.tpl and NOTES.txt included).
# values.yaml carries the bundle's image digests (image.manager,
# operatorImageEnv.*). Skipping it ships new templates against stale images.
STAGE="${OUT}/stage"
mkdir -p "${STAGE}"
cp "${CHART_YAML}" "${STAGE}/Chart.yaml"
cp -r "${OUT}/crds" "${STAGE}/crds"
cp -r "${OUT}/templates" "${STAGE}/templates"
cp "${OUT}/values.yaml" "${STAGE}/values.yaml"
for F in "${CHART_DIR}"/.helmignore "${CHART_DIR}"/README.md; do
  [[ -e "${F}" ]] && cp "${F}" "${STAGE}/"
done

sed_i "${STAGE}/Chart.yaml" "s/^version:.*/version: ${VERSION}/"
sed_i "${STAGE}/Chart.yaml" "s/^appVersion:.*/appVersion: ${VERSION}/"
sed_i "${STAGE}/Chart.yaml" "s|kubectl-catalog.io/channel:.*|kubectl-catalog.io/channel: ${CHANNEL}|"

# Render description as a literal block (real newlines, no "\n" escapes). The
# string value is unchanged, only its style, so reruns produce no diff.
yq -i '.description style="literal"' "${STAGE}/Chart.yaml"
echo "Chart.yaml: version ${VERSION}, channel ${CHANNEL}"

# ── Validate (staged copy) ───────────────────────────────────────────
helm lint "${STAGE}"
# --include-crds: render crds/ too, so a broken CRD fails here.
helm template release-test "${STAGE}" --include-crds > /dev/null

# ── Install ──────────────────────────────────────────────────────────
rm -rf "${CHART_DIR}/crds" "${CHART_DIR}/templates"
cp -r "${STAGE}/crds" "${CHART_DIR}/crds"
cp -r "${STAGE}/templates" "${CHART_DIR}/templates"
cp "${STAGE}/values.yaml" "${CHART_DIR}/values.yaml"
cp "${STAGE}/Chart.yaml" "${CHART_YAML}"
echo "Chart updated: ${CHART_DIR}"
