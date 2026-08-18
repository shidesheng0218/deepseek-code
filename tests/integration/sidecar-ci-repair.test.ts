import { afterEach, describe, expect, test } from 'vitest';
import { createServer, type Server } from 'node:http';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

interface RuntimeFrame {
  type: 'event' | 'response';
  ok: boolean;
  sessionID?: string;
  event?: { type: string; repairSessionID?: string };
  result?: unknown;
}

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length) await cleanups.pop()?.();
});

function startModelServer(): Promise<{ server: Server; baseURL: string }> {
  let requestCount = 0;
  const server = createServer((request, response) => {
    request.resume();
    request.on('end', () => {
      requestCount += 1;
      response.writeHead(200, { 'Content-Type': 'text/event-stream' });
      if (requestCount === 1) {
        response.end('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"ci-log","function":{"name":"github_ci_failure_log","arguments":"{\\"runID\\":42}"}}]}}]}\n\ndata: [DONE]\n\n');
      } else if (requestCount === 2) {
        response.end('data: {"choices":[{"delta":{"content":"已创建 CI 修复会话。"}}]}\n\ndata: [DONE]\n\n');
      } else {
        response.end('data: {"choices":[{"delta":{"content":"已完成 CI 修复分析。"}}]}\n\ndata: [DONE]\n\n');
      }
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Model server did not bind a TCP port');
    resolve({ server, baseURL: `http://127.0.0.1:${address.port}/v1` });
  }));
}

function waitForRepairCompletion(child: ChildProcessWithoutNullStreams): Promise<RuntimeFrame[]> {
  return new Promise((resolve, reject) => {
    const frames: RuntimeFrame[] = [];
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error('Timed out waiting for CI repair session')), 15_000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as RuntimeFrame;
        frames.push(frame);
        if (frame.event?.type === 'ci_repair_session_completed') {
          clearTimeout(timeout);
          resolve(frames);
        }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
    child.stderr.on('data', (chunk: string) => { void chunk; });
  });
}

describe('Agent Sidecar CI repair session', () => {
  test('creates, runs and mirrors a deferred child repair session after a GitHub Actions failure', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-sidecar-ci-'));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const project = join(root, 'project');
    const bin = join(root, 'bin');
    await mkdir(project, { recursive: true });
    await mkdir(bin, { recursive: true });
    await writeFile(join(bin, 'git'), '#!/usr/bin/env sh\nprintf "%s\\n" abc123\n');
    await writeFile(join(bin, 'gh'), '#!/usr/bin/env sh\nprintf "%s\\n" "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz1234567890" "src/login.ts:14: error TS2322: Type number is not assignable to type string"\n');
    await Promise.all([import('node:fs/promises').then(({ chmod }) => chmod(join(bin, 'git'), 0o755)), import('node:fs/promises').then(({ chmod }) => chmod(join(bin, 'gh'), 0o755))]);

    const { server, baseURL } = await startModelServer();
    cleanups.push(() => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
    const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
    const sidecar = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], {
      cwd: process.cwd(),
      env: { ...process.env, DEEPSEEK_SESSION_ROOT: join(root, 'sessions'), PATH: `${bin}:${process.env.PATH ?? ''}` }
    });
    cleanups.push(async () => { sidecar.kill('SIGKILL'); });

    const completion = waitForRepairCompletion(sidecar);
    sidecar.stdin.end(`${JSON.stringify({
      id: 'parent-run', method: 'session.run', params: {
        sessionID: 'parent-session', projectPath: project, prompt: '检查失败的 CI 并修复。', baseURL, apiKey: 'sk-test-key', model: 'deepseek-chat', mode: 'auto'
      }
    })}\n`);
    const frames = await completion;
    const created = frames.find((frame) => frame.sessionID === 'parent-session' && frame.event?.type === 'ci_repair_session_created');
    const started = frames.find((frame) => frame.sessionID === 'parent-session' && frame.event?.type === 'ci_repair_session_started');
    const completed = frames.find((frame) => frame.sessionID === 'parent-session' && frame.event?.type === 'ci_repair_session_completed');
    expect(created?.event?.repairSessionID).toMatch(/^ci-repair-/);
    expect(started?.event?.repairSessionID).toBe(created?.event?.repairSessionID);
    expect(completed?.event?.repairSessionID).toBe(created?.event?.repairSessionID);

    const childLog = await readFile(join(root, 'sessions', `${created?.event?.repairSessionID}.jsonl`), 'utf8');
    expect(childLog).toContain('repair_session_admitted');
    expect(childLog).toContain('repair_session_completed');
    expect(childLog).not.toContain('sk-test-key');
    expect(childLog).not.toContain('ghp_abcdefghijklmnopqrstuvwxyz1234567890');
  });
});
