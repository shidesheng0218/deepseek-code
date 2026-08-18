import { afterEach, describe, expect, test } from 'vitest';
import { createServer, type Server } from 'node:http';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { while (cleanups.length) await cleanups.pop()?.(); });

function waitForResponse(child: ChildProcessWithoutNullStreams, id: string): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error('Timed out waiting for Sidecar response')), 10_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as { id?: string; type?: string; ok?: boolean; result?: unknown };
        if (frame.id === id && frame.type === 'response' && frame.result && typeof frame.result === 'object' && 'text' in frame.result) {
          clearTimeout(timeout);
          resolve(frame.result as Record<string, unknown>);
        }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

describe('Agent Sidecar Anthropic Messages route', () => {
  test('executes an Anthropic streamed tool call and continues the same conversation', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-sidecar-anthropic-'));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const project = join(root, 'project');
    await mkdir(project, { recursive: true });
    await writeFile(join(project, 'README.md'), '# Anthropic fixture\n');

    let calls = 0;
    let receivedPath = '';
    let receivedKey = '';
    const server: Server = createServer((request, response) => {
      calls += 1;
      receivedPath = request.url ?? '';
      receivedKey = String(request.headers['x-api-key'] ?? '');
      request.resume();
      request.on('end', () => {
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        if (calls === 1) {
          response.end([
            'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_read","name":"read_file","input":{}}}\n\n',
            'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"README.md\\"}"}}\n\n',
            'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n',
            'event: message_stop\ndata: {"type":"message_stop"}\n\n'
          ].join(''));
        } else {
          response.end('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"已读取 README。"}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n');
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    cleanups.push(() => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Anthropic fixture did not bind a TCP port');

    const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
    const sidecar = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_SESSION_ROOT: join(root, 'sessions') } });
    cleanups.push(async () => { sidecar.kill('SIGKILL'); });
    const completion = waitForResponse(sidecar, 'anthropic-run');
    sidecar.stdin.end(`${JSON.stringify({ id: 'anthropic-run', method: 'session.run', params: { sessionID: 'anthropic-session', projectPath: project, prompt: '读取 README', baseURL: `http://127.0.0.1:${address.port}`, apiKey: 'anthropic-test-key', model: 'claude-test', protocol: 'anthropic-messages', mode: 'auto' } })}\n`);

    expect(await completion).toMatchObject({ text: '已读取 README。', status: 'completed' });
    expect(receivedPath).toBe('/v1/messages');
    expect(receivedKey).toBe('anthropic-test-key');
    expect(calls).toBe(2);
  });
});
