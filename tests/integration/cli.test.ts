import { afterEach, describe, expect, test } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const roots: string[] = [];
afterEach(async () => { while (roots.length) await rm(roots.pop()!, { recursive: true, force: true }); });

function runCLI(args: string[], env: NodeJS.ProcessEnv = {}): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['bin/deepseek.mjs', ...args], { cwd: process.cwd(), env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; }); child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject); child.once('exit', (code) => resolve({ code, stdout, stderr }));
  });
}

describe('DeepSeek Code CLI', () => {
  test('doctor uses the bundled sidecar health command', async () => {
    const result = await runCLI(['doctor'], { DEEPSEEK_RUNTIME_BINARY: join(process.cwd(), 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime') });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('deepseek-agent-runtime');
  });

  test('session list and attach read the same JSONL session store as the desktop app', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-cli-sessions-')); roots.push(root);
    await writeFile(join(root, 'cli-session.jsonl'), `${JSON.stringify({ type: 'turn_started', payload: { prompt: '修复 CLI 会话' } })}\n${JSON.stringify({ type: 'assistant_text', payload: { text: '已完成。' } })}\n${JSON.stringify({ type: 'turn_ended', payload: { status: 'completed' } })}\n`);
    const list = await runCLI(['session', 'list'], { DEEPSEEK_SESSION_ROOT: root });
    expect(list.code).toBe(0);
    expect(list.stdout).toContain('cli-session');
    const attach = await runCLI(['session', 'attach', 'cli-session'], { DEEPSEEK_SESSION_ROOT: root });
    expect(attach.code).toBe(0);
    expect(attach.stdout).toContain('修复 CLI 会话');
    expect(attach.stdout).toContain('已完成。');
  });

  test('session fork and branches work through the bundled sidecar', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-cli-fork-')); roots.push(root);
    const events = [
      { type: 'turn_started', payload: { prompt: '源问题', projectPath: '/tmp/demo' } },
      { type: 'assistant_text', payload: { text: '源回答。' } },
      { type: 'turn_ended', payload: { status: 'completed' } }
    ];
    const lines = events.map((event, index) => JSON.stringify({ schemaVersion: 1, eventID: `e${index}`, sessionID: 'cli-src', sequence: index + 1, ...event, createdAt: new Date().toISOString() }));
    await writeFile(join(root, 'cli-src.jsonl'), `${lines.join('\n')}\n`);
    const env = { DEEPSEEK_RUNTIME_BINARY: join(process.cwd(), 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime'), DEEPSEEK_SESSION_ROOT: root };

    const fork = await runCLI(['session', 'fork', 'cli-src', '--reason', 'CLI 验证'], env);
    expect(fork.code).toBe(0);
    const match = /^(fork-[a-z0-9-]+)\t/m.exec(fork.stdout);
    expect(match?.[1]).toBeTruthy();
    expect(fork.stdout).toContain('继承 2 条消息');

    const branches = await runCLI(['session', 'branches', 'cli-src'], env);
    expect(branches.code).toBe(0);
    expect(branches.stdout).toContain(match?.[1] ?? '');

    const replay = await runCLI(['session', 'replay', 'cli-src'], env);
    expect(replay.code).toBe(0);
    expect(replay.stdout).toContain('回放校验');
  });
});
