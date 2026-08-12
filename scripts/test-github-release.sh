#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-macos-release.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-code-release-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -x "$PACKAGE_SCRIPT" ]]; then
  echo "Expected release packager at $PACKAGE_SCRIPT" >&2
  exit 1
fi

if RELEASE_VERSION=9.8.7 BUILD_NUMBER=123 RELEASE_OUTPUT_DIR="$WORK_DIR/unsigned" "$PACKAGE_SCRIPT" >/dev/null 2>&1; then
  echo "Release packager accepted an unsigned production build" >&2
  exit 1
fi

ALLOW_ADHOC_RELEASE=1 \
RELEASE_VERSION=9.8.7 \
BUILD_NUMBER=123 \
RELEASE_OUTPUT_DIR="$WORK_DIR/unsigned" \
"$PACKAGE_SCRIPT"

DMG="$WORK_DIR/unsigned/DeepSeek-Code-9.8.7-arm64.dmg"
CHECKSUMS="$WORK_DIR/unsigned/SHA256SUMS.txt"
METADATA="$WORK_DIR/unsigned/release-metadata.json"

[[ -s "$DMG" ]]
[[ -s "$CHECKSUMS" ]]
[[ -s "$METADATA" ]]
hdiutil imageinfo "$DMG" >/dev/null
"$ROOT_DIR/scripts/verify-macos-release.sh" "$DMG"
grep -F "DeepSeek-Code-9.8.7-arm64.dmg" "$CHECKSUMS" >/dev/null
grep -F '"marketingVersion": "9.8.7"' "$METADATA" >/dev/null
grep -F '"buildNumber": "123"' "$METADATA" >/dev/null
grep -F '"distribution": "local-adhoc-test"' "$METADATA" >/dev/null

echo "GitHub release packaging checks passed"
