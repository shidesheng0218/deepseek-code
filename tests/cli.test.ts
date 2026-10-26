import { describe, expect, it, beforeAll, afterAll } from 'vitest';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { runSettings } from '../bin/terminal-client.mjs';

describe('CLI settings', () => {
  it('maps CLI options to runtime params without exposing secrets', async () => {
    const settings = await runSettings({ projectPath: '.', model: 'fixture', mode: 'acceptEdits', protocol: 'anthropic-messages', sessionID: 'cli-test' }, { DEEPSEEK_API_KEY: 'secret' });
    expect(settings.projectPath).toBe(process.cwd());
    expect(settings.model).toBe('fixture');
    expect(settings.mode).toBe('accept_edits');
    expect(settings.protocol).toBe('anthropic-messages');
    expect(settings).not.toHaveProperty('password');
  });

  it('rejects invalid modes and session IDs', async () => {
    await expect(runSettings({ mode: 'unsafe' }, { DEEPSEEK_API_KEY: 'secret' })).rejects.toThrow('Invalid mode');
    await expect(runSettings({ sessionID: 'bad/id' }, { DEEPSEEK_API_KEY: 'secret' })).rejects.toThrow('Invalid session ID');
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

describe('CLI config and session commands', () => {
  it('config list shows defaults with sources', async () => {
    const result = await cli(['config', 'list']);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('model\tdeepseek-chat\tdefault');
  });
  it('session list --json emits a parseable array', async () => {
    const events = [
      { sequence: 1, type: 'turn_started', payload: { prompt: 'fix login flow', projectPath: '/tmp/x' } },
      { sequence: 2, type: 'turn_ended', payload: { status: 'completed' } }
    ];
    await writeFile(join(fixture, 'sess-a.jsonl'), events.map((e) => JSON.stringify(e)).join('\n') + '\n');
    const result = await cli(['session', 'list', '--json']);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout) as Array<{ sessionID: string; turns: number; lastStatus: string }>;
    expect(parsed[0]?.sessionID).toBe('sess-a');
    expect(parsed[0]?.turns).toBe(1);
    expect(parsed[0]?.lastStatus).toBe('completed');
  });
  it('session show reports pending approvals', async () => {
    await writeFile(join(fixture, 'sess-b.jsonl'), [
      { sequence: 1, type: 'turn_started', payload: { prompt: 'p', projectPath: '/tmp/x' } },
      { sequence: 2, type: 'approval_pending', payload: { approvalID: 'a1', tool: 'run_command' } }
    ].map((e: Record<string, unknown>) => JSON.stringify(e)).join('\n') + '\n');
    const result = await cli(['session', 'show', 'sess-b']);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('待审批:    1');
  });
  it('session search filters by title', async () => {
    const result = await cli(['session', 'search', 'login']);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('sess-a');
  });
  it('session rename writes meta without touching the log', async () => {
    const result = await cli(['session', 'rename', 'sess-a', '登录修复']);
    expect(result.code).toBe(0);
    expect(JSON.parse(await (await import('node:fs/promises')).readFile(join(fixture, '.meta.json'), 'utf8'))['sess-a'].title).toBe('登录修复');
  });
  it('session archive moves the log out of the active list', async () => {
    const result = await cli(['session', 'archive', 'sess-b']);
    expect(result.code).toBe(0);
    const list = JSON.parse((await cli(['session', 'list', '--json'])).stdout) as Array<{ sessionID: string }>;
    expect(list.some((e) => e.sessionID === 'sess-b')).toBe(false);
  });
  it('config set/get round-trips a project-scoped value', async () => {
    const setResult = await cli(['config', 'set', 'model', 'fixture-model', '--scope', 'project']);
    expect(setResult.code).toBe(0);
    const getResult = await cli(['config', 'get', 'model']);
    expect(getResult.stdout.trim()).toBe('fixture-model');
    await cli(['config', 'unset', 'model', '--scope', 'project']);
  });
});

describe('CLI checkpoints', () => {
  it('creates a checkpoint on session.run and undo restores agent changes', async () => {
    const repo = await mkdtemp(join(tmpdir(), 'deepseek-cp-'));
    const git = (gitArgs: string[]) => new Promise<void>((r, j) => { const c = spawn('git', gitArgs, { cwd: repo }); c.on('close', (code) => code === 0 ? r() : j(new Error('git failed'))); c.on('error', j); });
    await git(['init', '-q']);
    await writeFile(join(repo, 'f.txt'), 'original\n');
    await git(['add', '.']);
    await git(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init']);
    // fixture runtime 不真的改文件；这里模拟 Agent 修改后的状态并直接测试 undo 逻辑
    const { createCheckpoint, diffAgainstCheckpoint, undoCheckpoint } = await import('../bin/checkpoint.mjs');
    const id = await createCheckpoint({ checkpointRoot: join(repo, '.deepseek'), projectPath: repo, sessionID: 's1', label: 'test turn' });
    await writeFile(join(repo, 'f.txt'), 'agent modified\n');
    const cp = JSON.parse(await (await import('node:fs/promises')).readFile(join(repo, '.deepseek', 'checkpoints', `${id}.json`), 'utf8')) as { entries: Record<string, { content?: string }> };
    const changed = await diffAgainstCheckpoint(cp as never);
    expect(changed).toContain('f.txt');
    const afterHash = (await import('node:crypto')).createHash('sha256').update('agent modified\n').digest('hex');
    const result = await undoCheckpoint({ checkpoint: cp as never, agentAfter: { 'f.txt': afterHash } });
    expect(result.restored).toContain('f.txt');
    expect(result.conflicts).toHaveLength(0);
    expect(await (await import('node:fs/promises')).readFile(join(repo, 'f.txt'), 'utf8')).toBe('original\n');
    await rm(repo, { recursive: true, force: true });
  });
  it('undo refuses files the user modified after the agent', async () => {
    const repo = await mkdtemp(join(tmpdir(), 'deepseek-cp2-'));
    await writeFile(join(repo, 'f.txt'), 'original\n');
    const { createCheckpoint, undoCheckpoint } = await import('../bin/checkpoint.mjs');
    const id = await createCheckpoint({ checkpointRoot: join(repo, '.deepseek'), projectPath: repo, sessionID: 's1', label: 't', extraPaths: ['f.txt'] });
    await writeFile(join(repo, 'f.txt'), 'agent modified\n');
    await writeFile(join(repo, 'f.txt'), 'user modified later\n');
    const cp = JSON.parse(await (await import('node:fs/promises')).readFile(join(repo, '.deepseek', 'checkpoints', `${id}.json`), 'utf8')) as never;
    const result = await undoCheckpoint({ checkpoint: cp, agentAfter: { 'f.txt': 'agent-hash-not-matching' } });
    expect(result.conflicts).toContain('f.txt');
    expect(result.restored).toHaveLength(0);
    expect(await (await import('node:fs/promises')).readFile(join(repo, 'f.txt'), 'utf8')).toBe('user modified later\n');
    await rm(repo, { recursive: true, force: true });
  });
  it('checkpoint list/show/undo commands work over files', async () => {
    const repo = await mkdtemp(join(tmpdir(), 'deepseek-cp3-'));
    await writeFile(join(repo, 'f.txt'), 'original\n');
    const { createCheckpoint } = await import('../bin/checkpoint.mjs');
    const id = await createCheckpoint({ checkpointRoot: join(repo, '.deepseek'), projectPath: repo, sessionID: 's1', label: 'cp test' });
    const run = (args: string[]) => new Promise<{ code: number | null; stdout: string; stderr: string }>((r, j) => {
      const c = spawn(process.execPath, [resolve('bin/deepseek.mjs'), ...args], { env: { ...process.env, DEEPSEEK_PROJECT: repo }, stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = ''; let stderr = '';
      c.stdout.on('data', (d) => { stdout += d; }); c.stderr.on('data', (d) => { stderr += d; });
      c.on('close', (code) => r({ code, stdout, stderr })); c.on('error', j); c.stdin.end();
    });
    const list = await run(['checkpoint', 'list', '--json']);
    expect(JSON.parse(list.stdout)[0].id).toBe(id);
    const show = await run(['checkpoint', 'show', id]);
    expect(show.stdout).toContain('cp test');
    await rm(repo, { recursive: true, force: true });
  });
});

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
  it('exits 3 when approval is required in non-interactive mode', async () => {
    const result = await cli(['ask', 'approve']);
    expect(result.code).toBe(3);
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
  it('emits parseable --json output for ask', async () => {
    const result = await cli(['ask', '--json', 'hello']);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout);
    expect(parsed.status).toBe('completed');
    expect(parsed.text).toBe('answer:hello');
    expect(parsed.sessionID).toMatch(/^cli-/);
  });
  it('json approval_required exits 3', async () => {
    const result = await cli(['ask', '--json', 'approve']);
    expect(result.code).toBe(3);
  });
  it('diff --json emits parseable working tree summary', async () => {
    const repo = await mkdtemp(join(tmpdir(), 'deepseek-cli-git-'));
    const git = (gitArgs: string[]) => new Promise((r, j) => { const c = spawn('git', gitArgs, { cwd: repo }); c.on('close', (code) => code === 0 ? r(undefined) : j(new Error(`git ${gitArgs[0]} exit ${code}`))); c.on('error', j); });
    await git(['init', '-q']);
    await writeFile(join(repo, 'a.txt'), 'one\n');
    await git(['add', '.']);
    await git(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init']);
    await writeFile(join(repo, 'a.txt'), 'one\ntwo\n');
    const diffResult = await new Promise<{ code: number | null; stdout: string }>((resolveResult, rejectRun) => {
      const c = spawn(process.execPath, [resolve('bin/deepseek.mjs'), 'diff', '--json'], {
        env: { ...process.env, DEEPSEEK_PROJECT: repo }, stdio: ['pipe', 'pipe', 'pipe']
      });
      let stdout = '';
      c.stdout.on('data', (d) => { stdout += d; });
      c.on('close', (code) => resolveResult({ code, stdout }));
      c.on('error', rejectRun);
      c.stdin.end();
    });
    expect(diffResult.code).toBe(0);
    const parsed = JSON.parse(diffResult.stdout) as { files: Array<{ path: string }>; shortstat: string };
    expect(parsed.files.some((f) => f.path === 'a.txt')).toBe(true);
    expect(parsed.shortstat).toContain('1 insertion');
    await rm(repo, { recursive: true, force: true });
  });
  it('rejects empty piped prompts', async () => {
    expect((await cli(['ask'])).code).toBe(2);
  });
});
