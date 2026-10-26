import { describe, expect, it, beforeAll, afterAll } from 'vitest';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { runSettings } from '../bin/terminal-client.mjs';

describe('CLI settings', () => {
  it('maps CLI options to runtime params without exposing secrets', () => {
    const settings = runSettings({ projectPath: '.', model: 'fixture', mode: 'acceptEdits', protocol: 'anthropic-messages', sessionID: 'cli-test' }, { DEEPSEEK_API_KEY: 'secret' });
    expect(settings.projectPath).toBe(process.cwd());
    expect(settings.model).toBe('fixture');
    expect(settings.mode).toBe('accept_edits');
    expect(settings.protocol).toBe('anthropic-messages');
    expect(settings).not.toHaveProperty('password');
  });

  it('rejects invalid modes and session IDs', () => {
    expect(() => runSettings({ mode: 'unsafe' }, { DEEPSEEK_API_KEY: 'secret' })).toThrow('Invalid mode');
    expect(() => runSettings({ sessionID: 'bad/id' }, { DEEPSEEK_API_KEY: 'secret' })).toThrow('Invalid session ID');
  });
});

let fixture: string;
let binary: string;
beforeAll(async () => {
  fixture = await mkdtemp(join(tmpdir(), 'deepseek-cli-test-'));
  binary = join(fixture, 'runtime');
  await writeFile(binary, `#!/usr/bin/env node
import { createInterface } from 'node:readline';
const send = frame => process.stdout.write(JSON.stringify(frame) + '\\n');
createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line);
  const { sessionID, prompt } = request.params;
  const event = event => send({ type: 'event', sessionID, event });
  if (prompt === 'crash') process.exit(7);
  if (prompt === 'error') return send({ type: 'response', id: request.id, ok: false, error: 'fixture failure' });
  if (prompt === 'approve') {
    event({ type: 'approval_required', id: 'approval-1', tool: 'run_command', risk: 'L2', preview: 'git push' });
    return send({ type: 'response', id: request.id, ok: true, result: { status: 'waiting_approval' } });
  }
  event({ type: 'assistant_text', text: 'answer:' + prompt });
  send({ type: 'response', id: request.id, ok: true, result: { text: 'answer:' + prompt, status: 'completed' } });
});
`, { mode: 0o755 });
});
afterAll(async () => { await rm(fixture, { recursive: true, force: true }); });

function cli(args: string[], input = '', runtime = binary): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(process.execPath, [resolve('bin/deepseek.mjs'), ...args], {
      env: { ...process.env, DEEPSEEK_API_KEY: 'fixture-key', DEEPSEEK_RUNTIME_BINARY: runtime, DEEPSEEK_SESSION_ROOT: fixture },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('CLI hung')); }, 5000);
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => { clearTimeout(timer); resolveResult({ code, stdout, stderr }); });
    child.stdin.end(input);
  });
}

describe('CLI process integration', () => {
  it('prints streamed text once, without repeating final response', async () => {
    const result = await cli(['ask', 'hello']);
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('answer:hello\n');
  });
  it('accepts piped prompts', async () => {
    const result = await cli(['ask'], 'pipe prompt');
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('answer:pipe prompt\n');
  });
  it('fails rather than auto-approving in non-interactive mode', async () => {
    const result = await cli(['ask', 'approve']);
    expect(result.code).toBe(2);
    expect(result.stderr).toContain('Approval required');
  });
  it('propagates runtime response failures', async () => {
    const result = await cli(['ask', 'error']);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('fixture failure');
  });
  it('exits on a crashed runtime', async () => {
    const result = await cli(['ask', 'crash']);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain('Runtime exited');
  });
  it('does not hang when the runtime executable is missing', async () => {
    const result = await cli(['ask', 'hello'], '', join(fixture, 'missing'));
    expect(result.code).toBe(1);
  });
  it('rejects empty piped prompts', async () => {
    expect((await cli(['ask'])).code).toBe(2);
  });
});
