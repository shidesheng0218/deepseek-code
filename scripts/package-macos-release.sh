#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_VERSION="${RELEASE_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist/release}"
NOTARIZE="${NOTARIZE:-0}"
REQUIRE_DEVELOPER_ID_SIGNATURE="${REQUIRE_DEVELOPER_ID_SIGNATURE:-0}"
DISTRIBUTION_LABEL="${DISTRIBUTION_LABEL:-}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "RELEASE_VERSION must be a SemVer-like value such as 0.1.0." >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must contain only digits." >&2
  exit 1
fi

if [[ "$REQUIRE_DEVELOPER_ID_SIGNATURE" == "1" && -z "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
  echo "A Developer ID signature is required by this invocation." >&2
  exit 1
fi

if [[ "$NOTARIZE" == "1" && -z "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
  echo "Notarization requires APPLE_CODESIGN_IDENTITY." >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/DeepSeek Code.app"
ARTIFACT_BASENAME="DeepSeek-Code-${RELEASE_VERSION}-arm64"
DMG_PATH="$RELEASE_OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$RELEASE_OUTPUT_DIR/SHA256SUMS.txt"
METADATA_PATH="$RELEASE_OUTPUT_DIR/release-metadata.json"
NOTARY_ZIP="$RELEASE_OUTPUT_DIR/${ARTIFACT_BASENAME}-notary.zip"
DMG_ROOT="$RELEASE_OUTPUT_DIR/.${ARTIFACT_BASENAME}.dmg-root.$$"

mkdir -p "$RELEASE_OUTPUT_DIR"
trap 'rm -rf "$DMG_ROOT"' EXIT

BUILD_VERSION_OVERRIDE="$BUILD_NUMBER" \
MARKETING_VERSION="$RELEASE_VERSION" \
REQUIRE_DEVELOPER_ID_SIGNATURE="$REQUIRE_DEVELOPER_ID_SIGNATURE" \
APPLE_CODESIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-}" \
"$ROOT_DIR/scripts/build-macos-app.sh"

NOTARIZED=false
if [[ "$NOTARIZE" == "1" ]]; then
  rm -f "$NOTARY_ZIP"
  ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"

  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  else
    echo "Notarization needs NOTARYTOOL_KEYCHAIN_PROFILE or APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID." >&2
    exit 1
  fi

  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  NOTARIZED=true
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP_DIR" "$DMG_ROOT/DeepSeek Code.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "DeepSeek Code" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

if [[ -n "$DISTRIBUTION_LABEL" ]]; then
  DISTRIBUTION="$DISTRIBUTION_LABEL"
elif [[ "$NOTARIZED" == "true" ]]; then
  DISTRIBUTION="developer-id-notarized"
elif [[ -n "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
  DISTRIBUTION="developer-id-signed-unnotarized"
else
  DISTRIBUTION="github-adhoc"
fi

(
  cd "$RELEASE_OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

cat > "$METADATA_PATH" <<JSON
{
  "product": "DeepSeek Code",
  "marketingVersion": "$RELEASE_VERSION",
  "buildNumber": "$BUILD_NUMBER",
  "architecture": "arm64",
  "artifact": "$(basename "$DMG_PATH")",
  "distribution": "$DISTRIBUTION",
  "notarized": $NOTARIZED
}
JSON

rm -f "$NOTARY_ZIP"
echo "Release DMG: $DMG_PATH"
echo "Checksums: $CHECKSUM_PATH"
echo "Metadata: $METADATA_PATH"
