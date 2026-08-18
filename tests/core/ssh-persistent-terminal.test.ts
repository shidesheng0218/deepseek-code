import { describe, expect, test } from 'vitest';
import { SSHRemotePersistentTerminal, type SSHInteractiveProcess, type SSHInteractiveRunner } from '../../src/core/ssh-persistent-terminal';

const host = { id: 'prod', hostname: 'example.test', user: 'deploy', port: 2222, fingerprint: 'SHA256:known', remotePath: '/home/deploy/.local/bin/deepseek-host' };

class FixtureProcess implements SSHInteractiveProcess {
  constructor(private readonly respondToExec = true) {}
  private readonly listeners = new Set<(line: string) => void>();
  private readonly exitListeners = new Set<(error?: Error) => void>();
  readonly writes: string[] = [];
  write(data: string): void {
    this.writes.push(data);
    const request = JSON.parse(data) as { type: string; requestID?: string; command?: string; afterSequence?: number };
    if (request.type === 'terminal_open') {
      this.emit({ protocolVersion: 1, type: 'terminal_opened', requestID: request.requestID, terminalID: 'remote-terminal-1', sequence: 0 });
    } else if (request.type === 'terminal_exec') {
      if (!this.respondToExec) return;
      const output = request.command === 'export DEEPSEEK_REMOTE=value; printf "$DEEPSEEK_REMOTE"' ? 'value' : '';
      this.emit({ protocolVersion: 1, type: 'terminal_completed', requestID: request.requestID, terminalID: 'remote-terminal-1', sequence: 1, command: request.command, stdout: output, stderr: '', exitCode: 0, completedAt: '2026-08-18T00:00:00.000Z' });
    } else if (request.type === 'terminal_read') {
      this.emit({ protocolVersion: 1, type: 'terminal_read_result', requestID: request.requestID, terminalID: 'remote-terminal-1', entries: request.afterSequence === 0 ? [{ sequence: 1, command: 'export DEEPSEEK_REMOTE=value; printf "$DEEPSEEK_REMOTE"', stdout: 'value', stderr: '', exitCode: 0, completedAt: '2026-08-18T00:00:00.000Z' }] : [] });
    } else if (request.type === 'terminal_close') {
      this.emit({ protocolVersion: 1, type: 'terminal_closed', requestID: request.requestID, terminalID: 'remote-terminal-1' });
    }
  }
  onLine(listener: (line: string) => void): () => void { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  onExit(listener: (error?: Error) => void): () => void { this.exitListeners.add(listener); return () => this.exitListeners.delete(listener); }
  async close(): Promise<void> { for (const listener of this.exitListeners) listener(); }
  emit(value: unknown): void { for (const listener of this.listeners) listener(JSON.stringify(value)); }
  disconnect(): void { for (const listener of this.exitListeners) listener(new Error('SSH connection lost')); }
}

describe('SSH persistent terminal', () => {
  test('opens, executes, attaches transcript by sequence, and preserves remote session state', async () => {
    const process = new FixtureProcess();
    const runner: SSHInteractiveRunner = { open: async () => process };
    const terminal = new SSHRemotePersistentTerminal(host, runner, async () => 'SHA256:known');

    await terminal.open('session-1');
    const first = await terminal.exec('export DEEPSEEK_REMOTE=value; printf "$DEEPSEEK_REMOTE"');
    const replay = await terminal.read(0);

    expect(first).toMatchObject({ state: 'completed', sequence: 1, stdout: 'value', exitCode: 0 });
    expect(replay).toHaveLength(1);
    expect(replay[0]).toMatchObject({ sequence: 1, stdout: 'value' });
    expect(process.writes.some((value) => JSON.parse(value).type === 'terminal_open')).toBe(true);
    await terminal.close();
  });

  test('marks an in-flight command indeterminate after SSH disconnect', async () => {
    const process = new FixtureProcess(false);
    const runner: SSHInteractiveRunner = { open: async () => process };
    const terminal = new SSHRemotePersistentTerminal(host, runner, async () => 'SHA256:known');
    await terminal.open('session-1');
    const pending = terminal.exec('make deploy', 50);
    process.disconnect();

    await expect(pending).resolves.toMatchObject({ state: 'indeterminate', retry: 'manual' });
    await terminal.close();
  });
});
