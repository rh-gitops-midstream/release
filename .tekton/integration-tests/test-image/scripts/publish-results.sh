#!/usr/bin/env bash
set -euo pipefail

RESULTS_REPO="git@github.com:rh-gitops-release-qa/catalog-results.git"
RESULTS_FILE="results.jsonl"

echo "Publishing pipeline results to ${RESULTS_REPO}..."

mkdir -p ~/.ssh
cp /deploy-key/ssh-privatekey ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
if [[ -f /deploy-key/known-hosts ]]; then
  cp /deploy-key/known-hosts ~/.ssh/known_hosts
else
  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
fi

REPO_DIR=$(mktemp -d)
git clone --depth 1 "${RESULTS_REPO}" "${REPO_DIR}"

SHARED_DIR="${SHARED_DIR:-/shared}"

python3 -c '
import json, os, datetime

record = {
    "pipeline": os.environ.get("PIPELINE_NAME", ""),
    "pipelineRun": os.environ.get("PIPELINE_RUN_NAME", ""),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": os.environ.get("AGGREGATE_STATUS", ""),
    "openshiftVersion": os.environ.get("OPENSHIFT_VERSION", ""),
    "resolvedOpenshiftVersion": os.environ.get("RESOLVED_OPENSHIFT_VERSION", ""),
    "operatorChannel": os.environ.get("OPERATOR_CHANNEL", ""),
    "installedCSV": os.environ.get("INSTALLED_CSV", ""),
    "argocdVersion": os.environ.get("ARGOCD_VERSION", ""),
    "testScript": os.environ.get("TEST_SCRIPT", ""),
    "fipsEnabled": os.environ.get("FIPS_ENABLED", ""),
    "upgrade": os.environ.get("UPGRADE", ""),
    "logUrl": os.environ.get("LOG_URL", ""),
    "logsArtifact": os.environ.get("LOGS_ARTIFACT", ""),
}

test_results = os.path.join(os.environ.get("SHARED_DIR", "/shared"), "test-results.json")
if os.path.isfile(test_results):
    with open(test_results) as f:
        tr = json.load(f)
    record["testsTotal"] = tr.get("total", 0)
    record["testsPassed"] = tr.get("passed", 0)
    record["testsFailed"] = tr.get("failed", 0)
    record["testsSkipped"] = tr.get("skipped", 0)
    record["testsErrors"] = tr.get("errors", 0)
    record["failedTests"] = tr.get("failedTests", [])
    # Derive status from actual test results, not pipeline aggregate
    if tr.get("total", 0) > 0 and tr.get("failed", 0) == 0 and tr.get("errors", 0) == 0:
        record["status"] = "Succeeded"
    elif tr.get("failed", 0) > 0 or tr.get("errors", 0) > 0:
        record["status"] = "Failed"

build_metadata = os.path.join(os.environ.get("SHARED_DIR", "/shared"), "build-metadata.json")
if os.path.isfile(build_metadata):
    with open(build_metadata) as f:
        bm = json.load(f)
    record["buildMetadata"] = bm

print(json.dumps(record, separators=(",", ":")))
' >> "${REPO_DIR}/${RESULTS_FILE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/render-results.py" ]]; then
  echo "Rendering dashboard..."
  python3 "${SCRIPT_DIR}/render-results.py" "${REPO_DIR}"
fi

cd "${REPO_DIR}"
git add -A
git config user.name "Konflux Pipeline"
git config user.email "noreply@konflux-ci.dev"
git commit -m "Add results: ${PIPELINE_RUN_NAME:-unknown}"

PUBLISHED=false
for attempt in 1 2 3; do
  if git push; then
    echo "Results published successfully"
    PUBLISHED=true
    break
  fi
  echo "Push failed (attempt ${attempt}/3), rebasing and retrying..."
  git pull --rebase || true
done
if [[ "$PUBLISHED" != "true" ]]; then
  echo "ERROR: Failed to publish results after 3 attempts"
  exit 1
fi

rm -rf "${REPO_DIR}"
