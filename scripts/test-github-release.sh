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

if REQUIRE_DEVELOPER_ID_SIGNATURE=1 RELEASE_VERSION=9.8.7 BUILD_NUMBER=123 RELEASE_OUTPUT_DIR="$WORK_DIR/strict" "$PACKAGE_SCRIPT" >/dev/null 2>&1; then
  echo "Release packager accepted a strict unsigned build" >&2
  exit 1
fi

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
grep -F '"distribution": "github-adhoc"' "$METADATA" >/dev/null

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-code-cli-release.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
[[ -x "$MOUNT_DIR/DeepSeek Code.app/Contents/Resources/deepseekd" ]]
[[ -x "$MOUNT_DIR/DeepSeek Code.app/Contents/Resources/deepseek" ]]
[[ -x "$MOUNT_DIR/DeepSeek Code.app/Contents/Resources/deepseek-worker" ]]
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"

RELEASE_VERSION=9.8.7 \
BUILD_NUMBER=124 \
RELEASE_OUTPUT_DIR="$WORK_DIR/github-adhoc" \
DISTRIBUTION_LABEL=github-adhoc \
"$PACKAGE_SCRIPT"

GITHUB_METADATA="$WORK_DIR/github-adhoc/release-metadata.json"
grep -F '"buildNumber": "124"' "$GITHUB_METADATA" >/dev/null
grep -F '"distribution": "github-adhoc"' "$GITHUB_METADATA" >/dev/null

echo "GitHub release packaging checks passed"
