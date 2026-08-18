#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$root" <<'NODE'
const assert = require("assert")
const fs = require("fs")
const path = require("path")

const root = process.argv[2]
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8")
const json = (relative) => JSON.parse(read(relative))
const manifest = json("package.json")
const tauri = json("apps/deepseek-code-desktop/src-tauri/tauri.conf.json")
const sidecar = json("apps/deepseek-agent-runtime/package.json")
const capabilities = json("apps/deepseek-code-desktop/src-tauri/capabilities/default.json")
const cargo = read("apps/deepseek-code-desktop/src-tauri/Cargo.toml")
const rustMain = read("apps/deepseek-code-desktop/src-tauri/src/main.rs")

assert.strictEqual(manifest.scripts["dev:tauri"], "npm --prefix apps/deepseek-code-desktop run dev")
assert.strictEqual(manifest.scripts["build:tauri"], "npm --prefix apps/deepseek-code-desktop run build")
assert.strictEqual(tauri.productName, "DeepSeek Code")
assert.strictEqual(tauri.identifier, "com.deepseekcode.desktop")
assert.deepStrictEqual(tauri.bundle.externalBin, ["binaries/deepseek-agent-runtime"])
assert.strictEqual(sidecar.name, "@deepseek-code/agent-runtime")
assert.strictEqual(sidecar.scripts.build, "bun build ./src/main.ts --compile --outfile ./dist/deepseek-agent-runtime")
assert(fs.existsSync(path.join(root, "apps/deepseek-code-desktop/src/main.tsx")))
assert(fs.existsSync(path.join(root, "apps/deepseek-agent-runtime/src/main.ts")))
assert(fs.existsSync(path.join(root, "apps/deepseek-code-desktop/src-tauri/icons/icon.svg")))
assert(fs.existsSync(path.join(root, "apps/deepseek-code-desktop/src-tauri/icons/icon.png")))
assert(cargo.includes('tauri-plugin-shell = "2"'))
assert(rustMain.includes('app.shell().sidecar("deepseek-agent-runtime")'))
assert(rustMain.includes("tauri_plugin_shell::init()"))
assert(capabilities.permissions.some((permission) =>
  typeof permission === "object" && permission.identifier === "shell:allow-execute" &&
  permission.allow?.some((entry) => entry.name === "binaries/deepseek-agent-runtime" && entry.sidecar === true),
))

for (const relative of [
  "apps/deepseek-code-desktop/src-tauri/tauri.conf.json",
  "apps/deepseek-code-desktop/src-tauri/Cargo.toml",
  "apps/deepseek-code-desktop/src/main.tsx",
  "apps/deepseek-agent-runtime/src/main.ts",
]) {
  assert(!//i.test(read(relative)), `${relative} must not launch or embed  runtime`)
}
NODE

echo "Tauri DeepSeek Code product checks passed"
