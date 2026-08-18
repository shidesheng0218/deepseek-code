#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desktop="$root/apps/deepseek-code-desktop"
package_version="$(node -p "require(process.argv[1]).version" "$desktop/package.json")"
version="${RELEASE_VERSION:-$package_version}"
version="${version#v}"
artifact="$root/dist/DeepSeek-Code-${version}-arm64.dmg"
metadata="$root/dist/release-metadata.json"
checksums="$root/dist/SHA256SUMS.txt"

test -f "$artifact"
test -f "$metadata"
test -f "$checksums"
hdiutil verify "$artifact" >/dev/null

actual_hash="$(shasum -a 256 "$artifact" | awk '{print $1}')"
expected_hash="$(awk 'NR == 1 { print $1 }' "$checksums")"
test "$actual_hash" = "$expected_hash"

node - "$metadata" "$version" "$(basename "$artifact")" <<'NODE'
const assert = require("assert")
const fs = require("fs")
const [metadataPath, version, artifact] = process.argv.slice(2)
const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"))
assert.strictEqual(metadata.product, "DeepSeek Code")
assert.strictEqual(metadata.version, version)
assert.strictEqual(metadata.artifact, artifact)
assert.strictEqual(metadata.runtime, "tauri-sidecar")
assert.strictEqual(metadata.browserRuntime, "bundled-chromium-playwright-core")
assert.match(metadata.buildStamp, new RegExp(`^${version}-[0-9a-f]+$`))
NODE

mount_dir="$(mktemp -d /tmp/deepseek-code-release.XXXXXX)"
cleanup() {
  hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$artifact" >/dev/null
app="$mount_dir/DeepSeek Code.app"
test -x "$app/Contents/MacOS/deepseek-agent-runtime"
test -x "$app/Contents/Resources/browser/chrome-headless-shell"
test -f "$app/Contents/Resources/playwright-core/index.js"

echo "Tauri release verification passed"
