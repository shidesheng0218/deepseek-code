#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/DeepSeek-Code-<version>-arm64.dmg" >&2
  exit 64
fi

DMG_PATH="$1"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

RELEASE_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
METADATA_PATH="$RELEASE_DIR/release-metadata.json"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-code-release-mount.XXXXXX")"
ATTACHED=0

cleanup() {
  if [[ "$ATTACHED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil imageinfo "$DMG_PATH" >/dev/null
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
ATTACHED=1

APP_PATH="$MOUNT_DIR/DeepSeek Code.app"
if [[ ! -d "$APP_PATH" || ! -L "$MOUNT_DIR/Applications" ]]; then
  echo "DMG must contain DeepSeek Code.app and an Applications shortcut." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

if [[ -f "$METADATA_PATH" ]] && grep -Fq '"distribution": "developer-id-notarized"' "$METADATA_PATH"; then
  xcrun stapler validate "$APP_PATH"
  spctl -a -vv "$APP_PATH"
fi

echo "Verified release DMG: $DMG_PATH"
