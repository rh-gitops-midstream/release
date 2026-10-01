#!/bin/bash
# Print debug login command for the EaaS test cluster

API_SERVER=$(oc whoami --show-server 2>/dev/null || true)
PASS_FILE=$(find /credentials -name "*password" -type f 2>/dev/null | head -1)

if [[ -n "$API_SERVER" && -n "$PASS_FILE" ]]; then
  echo "========================================"
  echo "DEBUG: To log in to the test cluster:"
  echo "  oc login $API_SERVER -u kubeadmin -p <REDACTED> --insecure-skip-tls-verify"
  echo "========================================"
fi
