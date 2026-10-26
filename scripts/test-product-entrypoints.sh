#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$root" <<'NODE'
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const root = process.argv[2]
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8')
assert.strictEqual(manifest.scripts.dev, 'node bin/deepseek.mjs')
assert.strictEqual(manifest.scripts.start, 'node bin/deepseek.mjs')
assert.strictEqual(manifest.scripts.build, 'npm run build:agent-runtime')
assert.strictEqual(manifest.scripts['release:package'], 'bash scripts/package-cli-release.sh')
assert.strictEqual(manifest.scripts['release:verify'], 'bash scripts/verify-cli-release.sh')
assert.strictEqual(manifest.scripts['dev:tauri'], undefined)
assert.strictEqual(manifest.scripts['build:tauri'], undefined)
assert.strictEqual(manifest.devDependencies['eslint-plugin-react-hooks'], undefined)
assert.strictEqual(manifest.devDependencies['eslint-plugin-react-refresh'], undefined)
assert(readme.includes('npm ci'))
assert(readme.includes('npm run build'))
assert(readme.includes('npm link'))
assert(readme.includes('deepseek'))
assert(!readme.includes('Tauri 2'))
assert(!readme.includes('DeepSeek Code.app'))
NODE
echo "DeepSeek Code CLI product entrypoint checks passed"
