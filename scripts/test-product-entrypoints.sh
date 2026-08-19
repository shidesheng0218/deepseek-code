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
assert.strictEqual(manifest.scripts["dev:swift"], "cd macos/DeepSeekCode && swift run DeepSeekCode")
assert.strictEqual(manifest.scripts["release:package"], "bash scripts/package-tauri-release.sh")
assert.strictEqual(manifest.scripts["release:verify"], "bash scripts/verify-tauri-release.sh")
assert.strictEqual(manifest.scripts["build:swift"], undefined, "legacy Swift app build entry must stay removed")
assert.strictEqual(manifest.scripts["release:package:swift"], undefined, "legacy Swift release entry must stay removed")
assert.strictEqual(manifest.scripts["release:verify:swift"], undefined, "legacy Swift release verify entry must stay removed")
assert.strictEqual(manifest.scripts["release:test"], undefined, "legacy release test entry must stay removed")
assert.strictEqual(manifest.scripts["refresh:macos"], undefined, "legacy Swift install refresh entry must stay removed")
assert.strictEqual(manifest.scripts["dev:"], undefined)
assert.strictEqual(manifest.scripts["dev:cli"], undefined)
assert(!fs.existsSync(path.join(root, "scripts", "run--fusion.sh")))
assert(!fs.existsSync(path.join(root, "scripts", "run--fusion-desktop.sh")))
assert(readme.includes(" 上游参考"))
assert(readme.includes("不会作为 DeepSeek Code 的运行时或用户入口"))
assert(readme.includes("Tauri 2 + 本地 Agent Sidecar"))
NODE

echo "DeepSeek Code product entrypoint checks passed"
