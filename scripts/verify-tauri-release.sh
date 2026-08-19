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

updater_manifest="$root/dist/latest.json"
if [[ -f "$updater_manifest" ]]; then
  updater_tarball="$root/dist/DeepSeek-Code-${version}-arm64.app.tar.gz"
  updater_sig="$updater_tarball.sig"
  test -f "$updater_tarball"
  test -f "$updater_sig"
  node - "$updater_manifest" "$version" "$updater_sig" <<'NODE'
const assert = require("assert")
const fs = require("fs")
const [manifestPath, version, sigPath] = process.argv.slice(2)
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"))
const signature = fs.readFileSync(sigPath, "utf8").replace(/[\r\n]/g, "")
assert.strictEqual(manifest.version, `v${version}`)
assert.strictEqual(manifest.platforms["darwin-aarch64"].signature, signature)
assert.ok(manifest.platforms["darwin-aarch64"].url.endsWith(`DeepSeek-Code-${version}-arm64.app.tar.gz`))
NODE
fi

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

# When updater artifacts were produced, they must be internally consistent.
updater_json="$root/dist/latest.json"
if [[ -f "$updater_json" ]]; then
  updater_bundle="$root/dist/DeepSeek-Code-${version}-arm64.app.tar.gz"
  updater_sig="${updater_bundle}.sig"
  test -f "$updater_bundle"
  test -f "$updater_sig"
  node - "$updater_json" "$version" "$updater_sig" <<'NODE'
const assert = require("assert")
const fs = require("fs")
const [jsonPath, version, sigPath] = process.argv.slice(2)
const latest = JSON.parse(fs.readFileSync(jsonPath, "utf8"))
assert.strictEqual(latest.version, `v${version}`)
const platform = latest.platforms?.["darwin-aarch64"]
assert(platform, "latest.json must include darwin-aarch64")
assert(platform.url.endsWith(`DeepSeek-Code-${version}-arm64.app.tar.gz`), "updater URL must match the artifact name")
assert.strictEqual(platform.signature, fs.readFileSync(sigPath, "utf8").replace(/[\r\n]/g, ""))
NODE
fi

echo "Tauri release verification passed"
