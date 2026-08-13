#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_AND_INSTALL="$ROOT_DIR/scripts/build-and-install.sh"
DEV_REFRESH="$ROOT_DIR/scripts/dev-refresh-macos-app.sh"

if ! grep -Fq 'dev-refresh-macos-app.sh' "$BUILD_AND_INSTALL"; then
  echo "build-and-install.sh must delegate to dev-refresh-macos-app.sh so every local update uses one installer path." >&2
  exit 1
fi

if ! grep -Fq '"$LSREGISTER" -u "$APP_SRC"' "$DEV_REFRESH"; then
  echo "dev-refresh-macos-app.sh must unregister the dist app from LaunchServices before deleting it." >&2
  exit 1
fi

if ! grep -Fq 'rm -rf "$APP_SRC"' "$DEV_REFRESH"; then
  echo "dev-refresh-macos-app.sh must delete dist/DeepSeek Code.app after installing to /Applications." >&2
  exit 1
fi

for executable in 'Contents/MacOS/DeepSeekCode' 'Contents/Resources/deepseekd' 'Contents/Resources/deepseek-worker' 'Contents/Resources/DeepSeekCodeToolHost'; do
  if ! grep -Fq "$executable" "$DEV_REFRESH"; then
    echo "dev-refresh-macos-app.sh must stop the old bundled runtime before replacing the app: $executable" >&2
    exit 1
  fi
done

if ! grep -Fq '"$LSREGISTER" -f "$APP_DST"' "$DEV_REFRESH"; then
  echo "dev-refresh-macos-app.sh must register the canonical /Applications app after installation." >&2
  exit 1
fi

echo "Single installed app checks passed"
