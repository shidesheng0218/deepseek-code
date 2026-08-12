#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/DeepSeekCode"

cd "$PACKAGE_DIR"
swift build --product DeepSeekCodeToolHost
swift build --product DeepSeekCodeSSHLoopbackChecks
BIN_DIR="$(swift build --show-bin-path)"

DEEPSEEK_TOOLHOST_PATH="$BIN_DIR/DeepSeekCodeToolHost" \
  "$BIN_DIR/DeepSeekCodeSSHLoopbackChecks"
