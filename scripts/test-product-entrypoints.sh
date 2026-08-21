#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$root" <<'NODE'
const assert = require("assert")
const fs = require("fs")
const path = require("path")

const root = process.argv[2]
const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"))
const readme = fs.readFileSync(path.join(root, "README.md"), "utf8")

assert.strictEqual(
  manifest.scripts.dev,
  "npm run dev:tauri",
  "npm run dev must launch the DeepSeek Code Tauri desktop app",
)
assert.strictEqual(
  manifest.scripts["dev:tauri"],
  "npm --prefix apps/deepseek-code-desktop run dev",
)
assert.strictEqual(manifest.scripts.build, "npm run build:tauri")
assert.strictEqual(manifest.scripts["build:tauri"], "npm --prefix apps/deepseek-code-desktop run build")
assert.strictEqual(manifest.scripts["dev:swift"], undefined, "legacy Swift dev entry must stay removed")
assert.strictEqual(manifest.scripts["release:package"], "bash scripts/package-tauri-release.sh")
assert.strictEqual(manifest.scripts["release:verify"], "bash scripts/verify-tauri-release.sh")
assert.strictEqual(manifest.scripts["build:swift"], undefined, "legacy Swift app build entry must stay removed")
assert.strictEqual(manifest.scripts["release:package:swift"], undefined, "legacy Swift release entry must stay removed")
assert.strictEqual(manifest.scripts["release:verify:swift"], undefined, "legacy Swift release verify entry must stay removed")
assert.strictEqual(manifest.scripts["release:test"], undefined, "legacy release test entry must stay removed")
assert.strictEqual(manifest.scripts["refresh:macos"], undefined, "legacy Swift install refresh entry must stay removed")
assert.strictEqual(manifest.scripts["dev:cli"], undefined)
assert(readme.includes("Tauri 2 + 本地 Agent Sidecar"))
assert(readme.includes("`npm run dev`"), "README must document the default Tauri development entrypoint")
assert(readme.includes("`npm run build`"), "README must document the default Tauri build entrypoint")
assert(readme.includes("`npm run release:package`"), "README must document the release packaging entrypoint")
assert(readme.includes("`node bin/deepseek.mjs doctor`"), "README must document the sidecar CLI health check")
assert(!readme.includes("macos/DeepSeekCode"), "README must not describe the removed Swift runtime")
assert(!readme.includes("DeepSeekCodeCore"), "README must not describe the removed Swift core")
assert(!readme.includes("Electron / React"), "README must not describe a removed Electron runtime")
assert(!readme.includes("dev:swift"), "README must not document a removed Swift command")
NODE

echo "DeepSeek Code product entrypoint checks passed"
