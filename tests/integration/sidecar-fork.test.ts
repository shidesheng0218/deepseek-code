import { afterEach, describe, expect, test } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createServer, type Server } from 'node:http';

const processes: ChildProcessWithoutNullStreams[] = [];
const servers: Server[] = [];
const roots: string[] = [];
afterEach(async () => {
  for (const child of processes.splice(0)) child.kill('SIGKILL');
  for (const server of servers.splice(0)) server.close();
  while (roots.length) await rm(roots.pop()!, { recursive: true, force: true });
});

function startSidecar(sessionRoot: string): ChildProcessWithoutNullStreams {
  const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
  const child = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ['pipe', 'pipe', 'pipe'] });
  processes.push(child);
  return child;
}

function collectFrames(child: ChildProcessWithoutNullStreams, responseID: string): Promise<{ frames: Array<Record<string, unknown>>; response: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const frames: Array<Record<string, unknown>> = [];
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${responseID}`)), 15_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n'); buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        frames.push(frame);
        if (frame.type === 'response' && frame.id === responseID) { clearTimeout(timeout); resolve({ frames, response: frame }); }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

function send(child: ChildProcessWithoutNullStreams, request: Record<string, unknown>): void {
  child.stdin.write(`${JSON.stringify(request)}\n`);
}

/** 捕获请求体的 mock Provider：固定回复一段文本。 */
function startMockProvider(captured: { body?: { messages?: Array<{ role: string; content: string }> } }): Promise<{ baseURL: string }> {
  const server = createServer((request, response) => {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; });
    request.on('end', () => {
      try { captured.body = JSON.parse(raw) as { messages?: Array<{ role: string; content: string }> }; } catch { /* ignore */ }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: '分叉后的回答。' } }] })}\n\n`);
      response.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 10, completion_tokens: 5, prompt_tokens_details: { cached_tokens: 0 } } })}\n\n`);
      response.end('data: [DONE]\n\n');
    });
  });
  servers.push(server);
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ baseURL: `http://127.0.0.1:${(server.address() as { port: number }).port}/v1/` }));
  });
}

const SOURCE_EVENTS = [
  { type: 'turn_started', payload: { prompt: '源会话的问题', projectPath: '/tmp/proj' } },
  { type: 'assistant_text', payload: { text: '源会话的回答。' } },
  { type: 'turn_ended', payload: { status: 'completed' } },
  { type: 'verification_passed', payload: { kind: 'terminal', command: 'npm test' } },
  { type: 'delivery_evaluated', payload: { state: 'delivered', reasons: [] } }
];

async function seedSource(root: string, sessionID: string): Promise<void> {
  const lines = SOURCE_EVENTS.map((event, index) => JSON.stringify({
    schemaVersion: 1, eventID: `e${index}`, sessionID, sequence: index + 1, type: event.type, payload: event.payload, createdAt: new Date().toISOString()
  }));
  await writeFile(join(root, `${sessionID}.jsonl`), `${lines.join('\n')}\n`);
}

describe('Agent Sidecar 会话分叉与回放', () => {
  test('session.fork 创建带血缘标记的新会话，branches 可查到', async () => {
    const sessionRoot = await mkdtemp(join(tmpdir(), 'deepseek-fork-'));
    roots.push(sessionRoot);
    await seedSource(sessionRoot, 'src-session');
    const child = startSidecar(sessionRoot);

    send(child, { id: 'fork-1', method: 'session.fork', params: { sessionID: 'src-session', baseSequence: 3, reason: '换模型重跑' } });
    const fork = (await collectFrames(child, 'fork-1')).response;
    expect(fork.ok).toBe(true);
    const forkResult = fork.result as { sessionID: string; baseSequence: number; inheritedMessages: number };
    expect(forkResult.baseSequence).toBe(3);
    expect(forkResult.inheritedMessages).toBe(2);

    const forkLog = await readFile(join(sessionRoot, `${forkResult.sessionID}.jsonl`), 'utf8');
    const firstEvent = JSON.parse(forkLog.split('\n')[0] ?? '{}') as { type: string; payload: Record<string, unknown> };
    expect(firstEvent.type).toBe('session_forked');
    expect(firstEvent.payload).toMatchObject({ sourceSessionID: 'src-session', baseSequence: 3, reason: '换模型重跑' });

    send(child, { id: 'branches-1', method: 'session.branches', params: { sessionID: 'src-session' } });
    const branches = (await collectFrames(child, 'branches-1')).response;
    const list = (branches.result as { branches: Array<{ sessionID: string; baseSequence: number }> }).branches;
    expect(list).toEqual([{ sessionID: forkResult.sessionID, baseSequence: 3 }]);
  });

  test('分叉会话的首轮运行继承源会话对话历史', async () => {
    const sessionRoot = await mkdtemp(join(tmpdir(), 'deepseek-fork-run-'));
    roots.push(sessionRoot);
    await seedSource(sessionRoot, 'src-run');
    const child = startSidecar(sessionRoot);

    send(child, { id: 'fork-run', method: 'session.fork', params: { sessionID: 'src-run' } });
    const fork = (await collectFrames(child, 'fork-run')).response;
    const forkID = (fork.result as { sessionID: string }).sessionID;

    const captured: { body?: { messages?: Array<{ role: string; content: string }> } } = {};
    const provider = await startMockProvider(captured);
    const projectPath = await mkdtemp(join(tmpdir(), 'deepseek-fork-project-'));
    roots.push(projectPath);

    send(child, {
      id: 'run-fork',
      method: 'session.run',
      params: { sessionID: forkID, projectPath, prompt: '分叉后的新问题', baseURL: provider.baseURL, apiKey: 'mock-key', model: 'mock-model', protocol: 'openai-compatible', mode: 'auto' }
    });
    const run = (await collectFrames(child, 'run-fork')).response;
    expect(run.ok).toBe(true);

    const contents = (captured.body?.messages ?? []).map((message) => message.content);
    expect(contents).toContain('源会话的问题');
    expect(contents).toContain('源会话的回答。');
    expect(contents).toContain('分叉后的新问题');
    const userOrder = contents.indexOf('源会话的问题');
    const assistantOrder = contents.indexOf('源会话的回答。');
    const newOrder = contents.indexOf('分叉后的新问题');
    expect(userOrder).toBeGreaterThanOrEqual(0);
    expect(assistantOrder).toBeGreaterThan(userOrder);
    expect(newOrder).toBeGreaterThan(assistantOrder);
  });

  test('session.replay 回放校验：重算门禁与记录在案的状态一致', async () => {
    const sessionRoot = await mkdtemp(join(tmpdir(), 'deepseek-replay-'));
    roots.push(sessionRoot);
    await seedSource(sessionRoot, 'replay-session');
    const child = startSidecar(sessionRoot);

    send(child, { id: 'replay-1', method: 'session.replay', params: { sessionID: 'replay-session' } });
    const replay = (await collectFrames(child, 'replay-1')).response;
    expect(replay.ok).toBe(true);
    const result = replay.result as { matched: boolean | null; gateState: string; recordedState?: string; turns: number; eventCount: number };
    expect(result.matched).toBe(true);
    expect(result.gateState).toBe('delivered');
    expect(result.recordedState).toBe('delivered');
    expect(result.turns).toBe(2);
    expect(result.eventCount).toBe(SOURCE_EVENTS.length);

    send(child, { id: 'replay-2', method: 'session.replay', params: { sessionID: 'replay-session', untilSequence: 3 } });
    const partial = (await collectFrames(child, 'replay-2')).response;
    const partialResult = partial.result as { matched: boolean | null; gateState: string; turns: number };
    expect(partialResult.matched).toBeNull();
    expect(partialResult.gateState).toBe('handoffReady');
    expect(partialResult.turns).toBe(2);
  });
});
