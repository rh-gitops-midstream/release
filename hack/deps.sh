#!/usr/bin/env bash
set -euo pipefail

echo ">>> Performing dependency check..."

OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

BIN_DIR="./bin"
mkdir -p "$BIN_DIR"

# Install yq
YQ_VERSION="v4.22.1"
YQ="yq-$YQ_VERSION"
YQ_BIN="$BIN_DIR/$YQ"
if [ ! -f "$YQ_BIN" ]; then
  echo ">>> Installing yq $YQ_VERSION..."
  curl -sSfLo "$YQ_BIN" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
  chmod +x "$YQ_BIN"
  ln -sf "$YQ" "$BIN_DIR/yq"
fi

# Install python dependencies
pip install -r requirements.txt 1> /dev/null

# Check if skopeo is installed
if ! command -v skopeo >/dev/null 2>&1; then
  echo "[warning] 'skopeo' is not installed. If you are running 'make bundle', please install skopeo."
fi

echo ">>> All required dependencies are installed."

# Export path and bin for downstream scripts if sourced
export YQ="$YQ_BIN"
export PATH="$BIN_DIR:$PATH"
