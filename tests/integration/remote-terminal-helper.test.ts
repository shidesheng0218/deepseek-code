import { afterEach, describe, expect, test } from 'vitest';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

const processes: ChildProcessWithoutNullStreams[] = [];
afterEach(async () => {
  for (const child of processes.splice(0)) child.kill('SIGKILL');
});

function framesFrom(child: ChildProcessWithoutNullStreams): Promise<Array<Record<string, unknown>>> {
  return new Promise((resolve, reject) => {
    const frames: Array<Record<string, unknown>> = [];
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error(`Timed out waiting for remote terminal helper: ${JSON.stringify(frames)}`)), 5_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        frames.push(JSON.parse(line) as Record<string, unknown>);
        if (frames.length >= 3) { clearTimeout(timeout); resolve(frames); }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

describe('remote terminal helper', () => {
  test('keeps one remote shell state and returns transcript entries through JSONL', async () => {
    const cwd = await mkdtemp(join(tmpdir(), 'deepseek-remote-terminal-'));
    const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
    const child = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--terminal-stdio'], { cwd: process.cwd(), stdio: ['pipe', 'pipe', 'pipe'] });
    processes.push(child);
    const frames = framesFrom(child);
    child.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'open-1', type: 'terminal_open', sessionID: 'remote-session', cwd })}\n`);
    child.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'exec-1', type: 'terminal_exec', terminalID: 'remote-remote-session', command: 'export DEEPSEEK_REMOTE=value; printf "$DEEPSEEK_REMOTE"' })}\n`);
    child.stdin.write(`${JSON.stringify({ protocolVersion: 1, requestID: 'read-1', type: 'terminal_read', terminalID: 'remote-remote-session', afterSequence: 0 })}\n`);

    const output = await frames;
    const opened = output.find((frame) => frame.type === 'terminal_opened');
    const completed = output.find((frame) => frame.type === 'terminal_completed');
    const read = output.find((frame) => frame.type === 'terminal_read_result');
    expect(opened).toMatchObject({ requestID: 'open-1', terminalID: expect.any(String) });
    expect(completed).toMatchObject({ requestID: 'exec-1', stdout: 'value', exitCode: 0, sequence: 1 });
    expect(read).toMatchObject({ requestID: 'read-1', entries: [expect.objectContaining({ stdout: 'value', sequence: 1 })] });
    await rm(cwd, { recursive: true, force: true });
  });
});
