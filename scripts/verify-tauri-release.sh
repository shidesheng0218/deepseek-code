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
NODE

echo "Tauri release verification passed"
