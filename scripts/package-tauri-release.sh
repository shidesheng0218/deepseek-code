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
# Sign updater bundles when a minisign private key is available; unsigned
# builds still produce the DMG, just no latest.json for auto-update.
# CI provides TAURI_SIGNING_PRIVATE_KEY directly; local builds use the key file.
if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  updater_key="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/deepseek-code.key}"
  if [[ -f "$updater_key" ]]; then
    export TAURI_SIGNING_PRIVATE_KEY_PATH="$updater_key"
    export TAURI_SIGNING_PRIVATE_KEY="$(cat "$updater_key")"
    export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-deepseek-updater-2026}"
  fi
else
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-deepseek-updater-2026}"
fi
(cd "$desktop" && ./node_modules/.bin/tauri build --config "{\"version\":\"$version\"}")
test -f "$source_dmg"
mkdir -p "$release_dir"
cp "$source_dmg" "$release_dmg"
shasum -a 256 "$release_dmg" > "$release_dir/SHA256SUMS.txt"

signing_mode="adhoc"
updater_tarball="$desktop/src-tauri/target/release/bundle/macos/DeepSeek Code.app.tar.gz"
updater_sig="$updater_tarball.sig"
if [[ -f "$updater_tarball" && -f "$updater_sig" ]]; then
  cp "$updater_tarball" "$release_dir/DeepSeek-Code-${version}-arm64.app.tar.gz"
  cp "$updater_sig" "$release_dir/DeepSeek-Code-${version}-arm64.app.tar.gz.sig"
  signing_mode="adhoc+updater"
  signature="$(tr -d '\r\n' < "$updater_sig")"
  node - "$release_dir/latest.json" "$version" "$signature" <<'NODE'
const fs = require("fs")
const [output, version, signature] = process.argv.slice(2)
const artifact = `DeepSeek-Code-${version}-arm64.app.tar.gz`
const url = `https://github.com/shidesheng0218/deepseek-code/releases/download/v${version}/${artifact}`
fs.writeFileSync(output, `${JSON.stringify({ version: `v${version}`, notes: "DeepSeek Code 自动更新", pub_date: new Date().toISOString(), platforms: { "darwin-aarch64": { signature, url } } }, null, 2)}\n`)
NODE
fi

build_stamp="${version}-$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
node - "$release_dir/release-metadata.json" "$version" "$(basename "$release_dmg")" "$build_stamp" "$signing_mode" <<'NODE'
const fs = require("fs")
const [output, version, artifact, buildStamp, signing] = process.argv.slice(2)
fs.writeFileSync(output, `${JSON.stringify({ product: "DeepSeek Code", version, artifact, buildStamp, runtime: "tauri-sidecar", browserRuntime: "bundled-chromium-playwright-core", signing }, null, 2)}\n`)
NODE

echo "Tauri release artifact: $release_dmg"
