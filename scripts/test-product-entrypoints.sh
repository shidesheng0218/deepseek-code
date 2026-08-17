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
  "cd macos/DeepSeekCode && swift run DeepSeekCode",
  "npm run dev must launch the DeepSeek Code Swift desktop app",
)
assert.strictEqual(
  manifest.scripts["dev:swift"],
  "cd macos/DeepSeekCode && swift run DeepSeekCode",
)
assert.strictEqual(manifest.scripts["dev:"], undefined)
assert.strictEqual(manifest.scripts["dev:cli"], undefined)
assert(!fs.existsSync(path.join(root, "scripts", "run--fusion.sh")))
assert(!fs.existsSync(path.join(root, "scripts", "run--fusion-desktop.sh")))
assert(readme.includes(" 上游参考"))
assert(readme.includes("不会作为 DeepSeek Code 的运行时或用户入口"))
NODE

echo "DeepSeek Code product entrypoint checks passed"
