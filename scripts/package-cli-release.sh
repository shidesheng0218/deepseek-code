#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${RELEASE_VERSION:-$(node -p "require(process.argv[1]).version" "$root/package.json")}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release version: $version" >&2
  exit 1
fi
[[ "$(uname -sm)" == "Darwin arm64" ]] || { echo "CLI release packaging currently supports Darwin arm64 only." >&2; exit 1; }
npm --prefix "$root" run build
runtime="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
test -x "$runtime"
release_dir="$root/dist"
mkdir -p "$release_dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/deepseek-code-cli"
artifact="$release_dir/DeepSeek-Code-${version}-darwin-arm64.tar.gz"
mkdir -p "$stage/apps/deepseek-agent-runtime/dist" "$stage/src"
cp "$root/package.json" "$root/README.md" "$root/LICENSE" "$stage/"
cp -R "$root/bin" "$stage/bin"
cp "$runtime" "$stage/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
cp -R "$root/src/core" "$stage/src/core"
node - "$stage/package.json" "$version" <<'NODE'
const fs = require('fs')
const [file, version] = process.argv.slice(2)
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'))
manifest.version = version
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + '\n')
NODE
chmod +x "$stage/bin/deepseek.mjs" "$stage/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
tar -C "$work" -czf "$artifact" deepseek-code-cli
shasum -a 256 "$artifact" > "$release_dir/SHA256SUMS.txt"
node - "$release_dir/release-metadata.json" "$version" "$(basename "$artifact")" "$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" <<'NODE'
const fs = require('fs')
const [output, version, artifact, revision] = process.argv.slice(2)
fs.writeFileSync(output, `${JSON.stringify({ product: 'DeepSeek Code CLI', version, artifact, buildStamp: `${version}-${revision}`, runtime: 'bun-compiled-agent-runtime', target: 'darwin-arm64' }, null, 2)}\n`)
NODE
echo "CLI release artifact: $artifact"
