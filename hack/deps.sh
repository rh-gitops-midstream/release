#!/usr/bin/env bash
set -euo pipefail

OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

BIN_DIR="./bin"
YQ_VERSION="v4.22.1"
YQ_BIN="$BIN_DIR/yq-$YQ_VERSION"

mkdir -p "$BIN_DIR"

if [ ! -f "$YQ_BIN" ]; then
  echo ">>> Installing yq $YQ_VERSION..."
  curl -sSfLo "$YQ_BIN" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
  chmod +x "$YQ_BIN"
fi

# Export path and bin for downstream scripts if sourced
export YQ="$YQ_BIN"
