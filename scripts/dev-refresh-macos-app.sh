#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT_DIR/dist/DeepSeek Code.app"
APP_DST="/Applications/DeepSeek Code.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$ROOT_DIR/scripts/build-macos-app.sh"

pkill -f "$APP_DST/Contents/MacOS/DeepSeekCode" 2>/dev/null || true
APP_STAGE="/Applications/.DeepSeek Code.app.stage.$$"
APP_BACKUP="/Applications/.DeepSeek Code.app.previous"
rm -rf "$APP_STAGE" "$APP_BACKUP"
ditto "$APP_SRC" "$APP_STAGE"
if [[ -e "$APP_DST" ]]; then mv "$APP_DST" "$APP_BACKUP"; fi
if ! mv "$APP_STAGE" "$APP_DST"; then
  [[ -e "$APP_BACKUP" ]] && mv "$APP_BACKUP" "$APP_DST"
  exit 1
fi
rm -rf "$APP_BACKUP"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP_SRC" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$APP_DST" >/dev/null 2>&1 || true
fi
rm -rf "$APP_SRC"
open "$APP_DST"

BUILD_STAMP="$(tr -d '\n' < "$APP_DST/Contents/Resources/build-stamp.txt" 2>/dev/null || true)"
echo "Refreshed: $APP_DST (build ${BUILD_STAMP:-unknown})"
