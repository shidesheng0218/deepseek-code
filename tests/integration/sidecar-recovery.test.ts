import { afterEach, describe, expect, test } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

const processes: ChildProcessWithoutNullStreams[] = [];
afterEach(async () => { for (const child of processes.splice(0)) child.kill('SIGKILL'); });

function startSidecar(sessionRoot: string): ChildProcessWithoutNullStreams {
  const bun = join(process.cwd(), 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
  const child = spawn(bun, ['apps/deepseek-agent-runtime/src/main.ts', '--stdio'], { cwd: process.cwd(), env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot }, stdio: ['pipe', 'pipe', 'pipe'] });
  processes.push(child);
  return child;
}

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
        if (frame.requestID === requestID || frame.id === requestID) { clearTimeout(timeout); resolve(frame); }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
  });
}

describe('Agent Sidecar crash recovery', () => {
  test('restores an unclaimed input and flags indeterminate and pending-approval state', async () => {
    const sessionRoot = await mkdtemp(join(tmpdir(), 'deepseek-recovery-'));
    const sessionID = 'recovery-session';
    const events = [
      { schemaVersion: 1, eventID: 'e1', commandID: 'c1', causationID: 'c1', correlationID: 'corr-1', sessionID, sequence: 1, type: 'input_enqueued', payload: { inputID: 'pending-1', prompt: '未完成的任务', projectPath: '/tmp/project' }, createdAt: new Date().toISOString() },
      { schemaVersion: 1, eventID: 'e2', commandID: 'c2', causationID: 'c2', correlationID: 'corr-1', sessionID, sequence: 2, type: 'tool_indeterminate', payload: { id: 'tool-9', tool: 'apply_patch' }, createdAt: new Date().toISOString() },
      { schemaVersion: 1, eventID: 'e3', commandID: 'c3', causationID: 'c3', correlationID: 'corr-1', sessionID, sequence: 3, type: 'approval_pending', payload: { approvalID: 'ap-1', tool: 'run_command', arguments: { command: 'git push' }, risk: 'L2' }, createdAt: new Date().toISOString() }
    ];
    await writeFile(join(sessionRoot, `${sessionID}.jsonl`), `${events.map((event) => JSON.stringify(event)).join('\n')}\n`);

    // Simulate a crash: start a sidecar against the same session root, then kill it.
    const first = startSidecar(sessionRoot);
    first.kill('SIGKILL');
    await new Promise((resolve) => setTimeout(resolve, 150));

    const second = startSidecar(sessionRoot);
    second.stdin.write(`${JSON.stringify({ id: 'recover-1', method: 'session.recover', params: { sessionID } })}\n`);
    const recovered = await nextFrame(second, 'recover-1');
    expect(recovered.ok).toBe(true);

    const log = await readFile(join(sessionRoot, `${sessionID}.jsonl`), 'utf8');
    expect(log).toContain('"type":"recovery_attention"');
    expect(log).toContain('indeterminate_tool');
    expect(log).toContain('pending_approval');
    await rm(sessionRoot, { recursive: true, force: true });
  });

  test('auto-restores a clean pending input and marks it resumable', async () => {
    const sessionRoot = await mkdtemp(join(tmpdir(), 'deepseek-recovery-clean-'));
    const sessionID = 'clean-session';
    const events = [
      { schemaVersion: 1, eventID: 'e1', commandID: 'c1', causationID: 'c1', correlationID: 'corr-2', sessionID, sequence: 1, type: 'input_enqueued', payload: { inputID: 'pending-clean', prompt: '继续任务', projectPath: '/tmp/project' }, createdAt: new Date().toISOString() }
    ];
    await writeFile(join(sessionRoot, `${sessionID}.jsonl`), `${events.map((event) => JSON.stringify(event)).join('\n')}\n`);

    const child = startSidecar(sessionRoot);
    child.stdin.write(`${JSON.stringify({ id: 'recover-clean', method: 'session.recover', params: { sessionID } })}\n`);
    const recovered = await nextFrame(child, 'recover-clean');
    expect(recovered.ok).toBe(true);
    const result = recovered.result as { restoredInputs: number; resumable: boolean };
    expect(result.restoredInputs).toBe(1);
    expect(result.resumable).toBe(true);
    await rm(sessionRoot, { recursive: true, force: true });
  });
});
