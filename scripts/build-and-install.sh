#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "🔨 Building and refreshing DeepSeek Code..."
bash "$ROOT_DIR/scripts/dev-refresh-macos-app.sh"

echo "Done! DeepSeek Code has been updated and launched."
