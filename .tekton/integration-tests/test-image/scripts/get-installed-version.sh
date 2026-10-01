#!/bin/bash
# Get the installed CSV version
# Environment variables expected:
# - NAMESPACE (default: openshift-gitops-operator)
# - KUBECONFIG
# - RESULT_PATH (path to write the result)
# - USE_SUBSCRIPTION (optional: "true" to get from subscription, "false" to get from CSV directly)

USE_SUBSCRIPTION="${USE_SUBSCRIPTION:-true}"

if [[ "$USE_SUBSCRIPTION" == "true" ]]; then
  # Catalog-based install: get CSV from subscription status
  CSV=$(oc get subscription -n "$NAMESPACE" -o jsonpath='{.items[0].status.installedCSV}' 2>/dev/null || echo "unknown")
else
  # Bundle-based install: get CSV directly
  CSV=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
fi

printf "%s" "$CSV" > "$RESULT_PATH"
echo "Installed CSV: $CSV"
