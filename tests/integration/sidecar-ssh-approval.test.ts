import { afterEach, describe, expect, test } from 'vitest';
import { createServer, type Server } from 'node:http';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { while (cleanups.length) await cleanups.pop()?.(); });

function waitForApproval(child: ChildProcessWithoutNullStreams): Promise<{ frames: Array<Record<string, unknown>>; response: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const frames: Array<Record<string, unknown>> = [];
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error('Timed out waiting for SSH approval')), 10_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        frames.push(frame);
        const event = frame.event as Record<string, unknown> | undefined;
        const result = frame.result as Record<string, unknown> | undefined;
        if (frame.type === 'response' && result?.status === 'waiting_approval') { clearTimeout(timeout); resolve({ frames, response: frame }); }
        if (event?.type === 'ssh_completed') { clearTimeout(timeout); reject(new Error('SSH executed before approval')); }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

describe('Agent Sidecar SSH capability', () => {
  test('exposes configured SSH only as an approval-gated structured tool', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-sidecar-ssh-'));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const project = join(root, 'project');
    await mkdir(join(project, '.deepseek'), { recursive: true });
    await writeFile(join(project, '.deepseek', 'ssh.json'), JSON.stringify({ hosts: [{ id: 'prod', hostname: 'example.test', user: 'deploy', port: 22, fingerprint: 'SHA256:known', remotePath: '/home/deploy/deepseek-host' }] }));

    const server: Server = createServer((request, response) => {
      request.resume();
      request.on('end', () => {
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        response.end('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"ssh-1","function":{"name":"ssh_execute","arguments":"{\\"hostID\\":\\"prod\\",\\"tool\\":\\"inspect_git\\",\\"arguments\\":{}}"}}]}}]}\n\ndata: [DONE]\n\n');
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    cleanups.push(() => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('SSH fixture did not bind a TCP port');

    const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
    const child = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_SESSION_ROOT: join(root, 'sessions') } });
    cleanups.push(async () => { child.kill('SIGKILL'); });
    const pending = waitForApproval(child);
    child.stdin.end(`${JSON.stringify({ id: 'ssh-run', method: 'session.run', params: { sessionID: 'ssh-session', projectPath: project, prompt: '读取远程 Git 状态', baseURL: `http://127.0.0.1:${address.port}/v1`, apiKey: 'fixture', model: 'fixture', mode: 'auto' } })}\n`);
    const { frames, response } = await pending;
    expect(response.ok).toBe(true);
    expect(frames.some((frame) => (frame.event as Record<string, unknown> | undefined)?.type === 'approval_required')).toBe(true);
    expect(frames.some((frame) => (frame.event as Record<string, unknown> | undefined)?.type === 'ssh_completed')).toBe(false);
  });
});
