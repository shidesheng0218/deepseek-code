import { afterEach, describe, expect, test } from 'vitest';
import { createServer, type Server } from 'node:http';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { while (cleanups.length) await cleanups.pop()?.(); });

describe('Agent Sidecar session inbox', () => {
  test('queues a second message submitted during an active turn and preserves conversation order', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-sidecar-queue-'));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const project = join(root, 'project');
    await mkdir(project, { recursive: true });
    const requests: Array<Record<string, unknown>> = [];
    const server: Server = createServer((request, response) => {
      let body = '';
      request.on('data', (chunk) => { body += chunk; });
      request.on('end', () => {
        const parsed = JSON.parse(body) as Record<string, unknown>;
        requests.push(parsed);
        const reply = () => {
          response.writeHead(200, { 'content-type': 'text/event-stream' });
          const text = requests.length === 1 ? '第一轮完成' : '第二轮完成';
          response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\ndata: [DONE]\n\n`);
        };
        if (requests.length === 1) setTimeout(reply, 120); else reply();
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    cleanups.push(() => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('queue fixture did not bind');
    const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
    const child = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_SESSION_ROOT: join(root, 'sessions') }, stdio: ['pipe', 'pipe', 'pipe'] });
    cleanups.push(async () => { child.kill('SIGKILL'); });
    const responses = new Map<string, Record<string, unknown>>();
    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        if (frame.type === 'response' && typeof frame.id === 'string') responses.set(frame.id, frame);
      }
    });
    const params = (prompt: string) => ({ sessionID: 'queue-session', projectPath: project, prompt, baseURL: `http://127.0.0.1:${address.port}/v1`, apiKey: 'fixture', model: 'fixture', mode: 'plan' });
    child.stdin.write(`${JSON.stringify({ id: 'run-1', method: 'session.run', params: params('第一轮问题') })}\n`);
    child.stdin.write(`${JSON.stringify({ id: 'run-2', method: 'session.run', params: params('第二轮问题') })}\n`);
    const deadline = Date.now() + 8_000;
    while ((!responses.has('run-1') || !responses.has('run-2')) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
    expect(responses.get('run-1')).toMatchObject({ ok: true, result: { text: '第一轮完成' } });
    expect(responses.get('run-2')).toMatchObject({ ok: true, result: { text: '第二轮完成' } });
    expect(requests).toHaveLength(2);
    expect((requests[1]?.messages as Array<{ role: string; content: string }>).slice(-3)).toEqual([
      { role: 'user', content: '第一轮问题' },
      { role: 'assistant', content: '第一轮完成' },
      { role: 'user', content: '第二轮问题' }
    ]);
    const eventLines = (await readFile(join(root, 'sessions', 'queue-session.jsonl'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(eventLines.length).toBeGreaterThan(0);
    expect(eventLines.every((event) => event.schemaVersion === 1 && typeof event.eventID === 'string' && typeof event.commandID === 'string' && typeof event.correlationID === 'string' && typeof event.sequence === 'number')).toBe(true);
    const types = eventLines.map((event) => String(event.type));
    expect(types).toEqual(expect.arrayContaining(['input_enqueued', 'input_claimed']));
    expect(types.indexOf('input_enqueued')).toBeLessThan(types.indexOf('input_claimed'));
  });
});
