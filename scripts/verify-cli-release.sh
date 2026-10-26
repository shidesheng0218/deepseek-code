#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${RELEASE_VERSION:-$(node -p "require(process.argv[1]).version" "$root/package.json")}"
version="${version#v}"
release_dir="$root/dist"
artifact="$release_dir/DeepSeek-Code-${version}-darwin-arm64.tar.gz"
metadata="$release_dir/release-metadata.json"
checksums="$release_dir/SHA256SUMS.txt"
test -f "$artifact" && test -f "$metadata" && test -f "$checksums"
actual_hash="$(shasum -a 256 "$artifact" | awk '{print $1}')"
expected_hash="$(awk 'NR == 1 { print $1 }' "$checksums")"
test "$actual_hash" = "$expected_hash"
node - "$metadata" "$version" "$(basename "$artifact")" <<'NODE'
const assert = require('assert')
const fs = require('fs')
const [path, version, artifact] = process.argv.slice(2)
const metadata = JSON.parse(fs.readFileSync(path, 'utf8'))
assert.strictEqual(metadata.product, 'DeepSeek Code CLI')
assert.strictEqual(metadata.version, version)
assert.strictEqual(metadata.artifact, artifact)
assert.strictEqual(metadata.runtime, 'bun-compiled-agent-runtime')
assert.strictEqual(metadata.target, 'darwin-arm64')
NODE
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
tar -xzf "$artifact" -C "$stage"
cli="$stage/deepseek-code-cli/bin/deepseek.mjs"
runtime="$stage/deepseek-code-cli/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
test -x "$cli" && test -x "$runtime"
test -f "$stage/deepseek-code-cli/src/core/delivery-receipt.ts"
DEEPSEEK_RUNTIME_BINARY="$runtime" node "$cli" --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' >/dev/null
DEEPSEEK_RUNTIME_BINARY="$runtime" node "$cli" --help | grep -F 'receipt verify' >/dev/null
DEEPSEEK_SESSION_ROOT="$stage/sessions" node "$cli" doctor | grep -F 'deepseek-agent-runtime' >/dev/null
node --input-type=module - "$stage/deepseek-code-cli" "$stage" <<'NODE'
import { writeFileSync, mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const [root, temp] = process.argv.slice(2);
const { buildDeliveryReceipt } = await import(pathToFileURL(join(root, 'src/core/delivery-receipt.ts')));
const { evaluateDeliveryGate } = await import(pathToFileURL(join(root, 'src/core/delivery-gate.ts')));
const events = [{ sequence: 1, type: 'turn_started', payload: { prompt: 'package verification' } }];
mkdirSync(join(temp, 'sessions'), { recursive: true });
writeFileSync(join(temp, 'sessions', 'release-smoke.jsonl'), events.map(event => JSON.stringify(event)).join('\n') + '\n');
writeFileSync(join(temp, 'receipt.json'), JSON.stringify(buildDeliveryReceipt({ sessionID: 'release-smoke', events, gate: evaluateDeliveryGate(events), projectPath: temp, receiptID: 'release-smoke', issuedAt: '2026-10-26T00:00:00Z' })));
NODE
DEEPSEEK_SESSION_ROOT="$stage/sessions" node "$cli" receipt verify "$stage/receipt.json" > "$stage/receipt-result.txt"
grep -F 'logHash' "$stage/receipt-result.txt" >/dev/null
echo "CLI release verification passed"
