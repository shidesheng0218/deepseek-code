#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/macos/DeepSeekCode"
BUILD_DIR="$SWIFT_DIR/.build/arm64-apple-macosx/release"
APP_DIR="$ROOT_DIR/dist/DeepSeek Code.app"
APP_STAGE="$ROOT_DIR/dist/.DeepSeek Code.app.stage.$$"
MARKETING_VERSION="${MARKETING_VERSION:-${RELEASE_VERSION:-0.1.0}}"
BUILD_VERSION="${BUILD_VERSION_OVERRIDE:-${BUILD_NUMBER:-${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}}}"
if [[ -z "${BUILD_VERSION_OVERRIDE:-}" && -z "${BUILD_NUMBER:-}" ]]; then
  GIT_REV="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -n "$GIT_REV" ]]; then BUILD_VERSION="${BUILD_VERSION}-${GIT_REV}"; fi
fi

cd "$SWIFT_DIR"
swift build --configuration release --product DeepSeekCode
swift build --configuration release --product DeepSeekCodeScheduler
swift build --configuration release --product DeepSeekCodeToolHost

rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources" "$APP_STAGE/Contents/Library"
cp "$BUILD_DIR/DeepSeekCode" "$APP_STAGE/Contents/MacOS/DeepSeekCode"
cp "$BUILD_DIR/DeepSeekCodeScheduler" "$APP_STAGE/Contents/Library/DeepSeekCodeScheduler"
cp "$BUILD_DIR/DeepSeekCodeToolHost" "$APP_STAGE/Contents/Resources/DeepSeekCodeToolHost"
printf '%s\n' "$BUILD_VERSION" > "$APP_STAGE/Contents/Resources/build-stamp.txt"

cat > "$APP_STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>DeepSeek Code</string>
  <key>CFBundleExecutable</key><string>DeepSeekCode</string>
  <key>CFBundleIdentifier</key><string>com.deepseekcode.desktop</string>
  <key>CFBundleName</key><string>DeepSeek Code</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
  # Sign nested executables first.  Signing the bundle with --deep masks
  # nested-signature problems and is unsuitable for a notarized release.
  codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" "$APP_STAGE/Contents/Library/DeepSeekCodeScheduler"
  codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" "$APP_STAGE/Contents/Resources/DeepSeekCodeToolHost"
  codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" "$APP_STAGE"
else
  if [[ "${REQUIRE_DEVELOPER_ID_SIGNATURE:-0}" == "1" ]]; then
    echo "APPLE_CODESIGN_IDENTITY is required for a GitHub production release." >&2
    exit 1
  fi
  # Ad-hoc signing remains intentionally limited to local development builds.
  codesign --force --deep --sign - "$APP_STAGE"
fi

codesign --verify --deep --strict "$APP_STAGE"

if [[ "${REQUIRE_DEVELOPER_ID_SIGNATURE:-0}" == "1" ]]; then
  SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_STAGE" 2>&1)"
  if ! grep -Fq "Authority=Developer ID Application" <<<"$SIGNING_DETAILS" || grep -Fq "TeamIdentifier=not set" <<<"$SIGNING_DETAILS"; then
    echo "A Developer ID Application signature is required for a GitHub production release." >&2
    exit 1
  fi
fi

if [[ -e "$APP_DIR" ]]; then
  rm -rf "$APP_DIR.previous"
  mv "$APP_DIR" "$APP_DIR.previous"
fi
mv "$APP_STAGE" "$APP_DIR"
rm -rf "$APP_DIR.previous"

echo "Built: $APP_DIR"
