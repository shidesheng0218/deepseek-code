import { afterEach, describe, expect, test } from 'vitest';
import { access, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

const children: ChildProcessWithoutNullStreams[] = [];
afterEach(async () => { for (const child of children.splice(0)) child.kill('SIGKILL'); });

function nextFrame(child: ChildProcessWithoutNullStreams, requestID: string): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${requestID}`)), 5_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n'); buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        if (frame.requestID === requestID) { clearTimeout(timeout); resolve(frame); }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

async function startHelper(socket: string, workspace: string): Promise<ChildProcessWithoutNullStreams> {
  const compiled = join(process.cwd(), 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime');
  const useCompiled = await access(compiled).then(() => true).catch(() => false);
  const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
  const child = useCompiled ? spawn(compiled, ['--terminal-stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_REMOTE_TERMINAL_SOCKET: socket, DEEPSEEK_REMOTE_WORKSPACE_ROOT: workspace }, stdio: ['pipe', 'pipe', 'pipe'] }) : spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--terminal-stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_REMOTE_TERMINAL_SOCKET: socket, DEEPSEEK_REMOTE_WORKSPACE_ROOT: workspace }, stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child);
  return child;
}

describe('remote terminal reconnect', () => {
  test('keeps the remote shell helper alive after the SSH proxy exits and allows Attach', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-remote-reconnect-'));
    const socket = join(root, 'terminal.sock');
    const first = await startHelper(socket, root);
    first.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'open', type: 'terminal_open', sessionID: 'reconnect-session', cwd: root })}\n`);
    const opened = await nextFrame(first, 'open');
    const terminalID = String(opened.terminalID);
    first.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'exec', type: 'terminal_exec', terminalID, command: 'export DEEPSEEK_RECONNECT=value; printf "$DEEPSEEK_RECONNECT"' })}\n`);
    await expect(nextFrame(first, 'exec')).resolves.toMatchObject({ type: 'terminal_completed', stdout: 'value', sequence: 1 });
    first.kill('SIGTERM');
    await new Promise((resolve) => setTimeout(resolve, 100));

    const second = await startHelper(socket, root);
    second.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'attach', type: 'terminal_attach', sessionID: 'reconnect-session', terminalID })}\n`);
    await expect(nextFrame(second, 'attach')).resolves.toMatchObject({ type: 'terminal_attached', terminalID });
    second.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'read', type: 'terminal_read', terminalID, afterSequence: 0 })}\n`);
    await expect(nextFrame(second, 'read')).resolves.toMatchObject({ type: 'terminal_read_result', entries: [expect.objectContaining({ sequence: 1, stdout: 'value' })] });
    second.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'close', type: 'terminal_close', terminalID })}\n`);
    await expect(nextFrame(second, 'close')).resolves.toMatchObject({ type: 'terminal_closed', terminalID });
    second.kill('SIGTERM');
    await rm(root, { recursive: true, force: true });
  });
});
