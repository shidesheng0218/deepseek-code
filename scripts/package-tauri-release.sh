#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desktop="$root/apps/deepseek-code-desktop"
package_version="$(node -p "require(process.argv[1]).version" "$desktop/package.json")"
version="${RELEASE_VERSION:-$package_version}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release version: $version" >&2
  exit 1
fi
source_dmg="$desktop/src-tauri/target/release/bundle/dmg/DeepSeek Code_${version}_aarch64.dmg"
release_dir="$root/dist"
release_dmg="$release_dir/DeepSeek-Code-${version}-arm64.dmg"

npm --prefix "$desktop" run prepare:sidecar
npm --prefix "$desktop" run prepare:browser
npm --prefix "$desktop" run build:web
(cd "$desktop" && ./node_modules/.bin/tauri build --config "{\"version\":\"$version\"}")
test -f "$source_dmg"
mkdir -p "$release_dir"
cp "$source_dmg" "$release_dmg"
shasum -a 256 "$release_dmg" > "$release_dir/SHA256SUMS.txt"

node - "$release_dir/release-metadata.json" "$version" "$(basename "$release_dmg")" <<'NODE'
const fs = require("fs")
const [output, version, artifact] = process.argv.slice(2)
fs.writeFileSync(output, `${JSON.stringify({ product: "DeepSeek Code", version, artifact, runtime: "tauri-sidecar", browserRuntime: "bundled-chromium-playwright-core", signing: "adhoc" }, null, 2)}\n`)
NODE

echo "Tauri release artifact: $release_dmg"
