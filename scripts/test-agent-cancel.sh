#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/apps/deepseek-agent-runtime/dist/deepseek-agent-runtime"
"$root/scripts/build-agent-sidecar.sh" >/dev/null

node - "$binary" "$root" <<'NODE'
const assert = require('assert'); const http = require('http'); const { spawn } = require('child_process'); const fs = require('fs'); const os = require('os'); const path = require('path');
const [binary, root] = process.argv.slice(2); const projectPath = fs.mkdtempSync(path.join(os.tmpdir(), 'deepseek-cancel-project-')); const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'deepseek-cancel-events-'));
const provider = http.createServer((_request, response) => { response.writeHead(200, { 'content-type': 'text/event-stream' }); });
provider.listen(0, '127.0.0.1', () => {
  const child = spawn(binary, ['--stdio'], { cwd: root, env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ['pipe', 'pipe', 'pipe'] });
  const frames = []; let buffer = ''; child.stdout.setEncoding('utf8'); child.stdout.on('data', (chunk) => { buffer += chunk; const lines = buffer.split('\n'); buffer = lines.pop() ?? ''; for (const line of lines) if (line.trim()) frames.push(JSON.parse(line)); });
  const params = { sessionID: 'cancel-session', projectPath, prompt: '耗时任务', baseURL: `http://127.0.0.1:${provider.address().port}/v1/`, apiKey: 'fixture', model: 'fixture', mode: 'auto' };
  child.stdin.write(`${JSON.stringify({ id: 'run', method: 'session.run', params })}\n`);
  setTimeout(() => child.stdin.write(`${JSON.stringify({ id: 'cancel', method: 'session.cancel', params: { sessionID: 'cancel-session' } })}\n`), 100);
  const deadline = Date.now() + 5000; const poll = () => { const final = frames.find((frame) => frame.id === 'run' && frame.type === 'response'); if (final) { try { assert.strictEqual(final.ok, true); assert.strictEqual(final.result.status, 'cancelled'); console.log('Agent runtime cancellation checks passed'); child.kill('SIGTERM'); provider.close(); } catch (error) { child.kill('SIGKILL'); provider.close(); throw error; } return; } if (Date.now() > deadline) { child.kill('SIGKILL'); provider.close(); throw new Error(JSON.stringify(frames)); } setTimeout(poll, 20); }; poll();
});
NODE
