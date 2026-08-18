import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import type { SSHFingerprintProbe, SSHHostConfig } from './ssh-tool-host';
import { buildSSHPersistentTerminalArguments, fingerprintMatches, validateSSHHost } from './ssh-tool-host';

export interface SSHInteractiveProcess {
  write(data: string): void;
  onLine(listener: (line: string) => void): () => void;
  onExit(listener: (error?: Error) => void): () => void;
  close(): Promise<void>;
}

export interface SSHInteractiveRunner {
  open(args: string[], timeoutMs: number): Promise<SSHInteractiveProcess>;
}

export interface SSHRemoteTerminalEntry {
  sequence: number;
  command: string;
  stdout: string;
  stderr: string;
  exitCode: number;
  completedAt: string;
}

export interface SSHRemoteTerminalResult extends SSHRemoteTerminalEntry {
  state: 'completed' | 'indeterminate';
  retry: 'none' | 'manual';
}

type PendingRequest = {
  type: 'terminal_open' | 'terminal_attach' | 'terminal_exec' | 'terminal_read' | 'terminal_close';
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

type RemoteFrame = {
  protocolVersion?: number;
  type?: string;
  requestID?: string;
  terminalID?: string;
  sequence?: number;
  command?: string;
  stdout?: string;
  stderr?: string;
  exitCode?: number;
  completedAt?: string;
  entries?: unknown;
  error?: string;
};

function stringValue(value: unknown): string | undefined { return typeof value === 'string' ? value : undefined; }
function integerValue(value: unknown): number | undefined { return typeof value === 'number' && Number.isInteger(value) ? value : undefined; }

function normalizeEntry(value: unknown): SSHRemoteTerminalEntry | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const candidate = value as Record<string, unknown>;
  const sequence = integerValue(candidate.sequence);
  const command = stringValue(candidate.command);
  const stdout = stringValue(candidate.stdout);
  const stderr = stringValue(candidate.stderr);
  const exitCode = integerValue(candidate.exitCode);
  const completedAt = stringValue(candidate.completedAt);
  if (sequence === undefined || sequence < 1 || command === undefined || stdout === undefined || stderr === undefined || exitCode === undefined || completedAt === undefined) return undefined;
  return { sequence, command, stdout, stderr, exitCode, completedAt };
}

function timeoutFor(host: SSHHostConfig, value?: number): number {
  return Math.min(Math.max(value ?? host.timeoutMs ?? 120_000, 1_000), 600_000);
}

export function createSystemSSHInteractiveRunner(): SSHInteractiveRunner {
  return {
    open: async (args, timeoutMs) => {
      const child: ChildProcessWithoutNullStreams = spawn('/usr/bin/ssh', args, { stdio: 'pipe' });
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      let stdoutBuffer = '';
      const lineListeners = new Set<(line: string) => void>();
      const exitListeners = new Set<(error?: Error) => void>();
      let exited = false;
      const notifyExit = (error?: Error): void => {
        if (exited) return;
        exited = true;
        for (const listener of exitListeners) listener(error);
      };
      const startTimeout = setTimeout(() => {
        notifyExit(new Error(`SSH terminal did not start within ${timeoutMs}ms`));
        child.kill('SIGTERM');
      }, timeoutMs);
      child.stdout.on('data', (chunk: string) => {
        clearTimeout(startTimeout);
        stdoutBuffer += chunk;
        const lines = stdoutBuffer.split('\n');
        stdoutBuffer = lines.pop() ?? '';
        for (const line of lines) if (line.trim()) for (const listener of lineListeners) listener(line);
      });
      child.stderr.on('data', () => {
        if (!exited) { /* stderr is protocol diagnostics; the exit handler establishes terminal state. */ }
      });
      child.once('error', (error) => { clearTimeout(startTimeout); notifyExit(error); });
      child.once('exit', (code, signal) => { clearTimeout(startTimeout); notifyExit(new Error(`SSH terminal disconnected (${code ?? signal ?? 'unknown'})`)); });
      return {
        write: (data) => { if (!exited) child.stdin.write(data); },
        onLine: (listener) => { lineListeners.add(listener); return () => lineListeners.delete(listener); },
        onExit: (listener) => { exitListeners.add(listener); return () => exitListeners.delete(listener); },
        close: async () => {
          if (!exited) child.stdin.end();
          await new Promise<void>((resolve) => child.once('exit', () => resolve()));
        }
      };
    }
  };
}

/**
 * A structured, long-lived remote terminal. The remote binary is invoked as
 * `deepseek-host --terminal-stdio`; it receives only JSONL requests and never
 * accepts an unstructured SSH shell command from the model.
 */
export class SSHRemotePersistentTerminal {
  private process: SSHInteractiveProcess | undefined;
  private terminalID: string | undefined;
  private readonly transcript = new Map<number, SSHRemoteTerminalEntry>();
  private readonly pending = new Map<string, PendingRequest>();
  private unsubscribeLine: (() => void) | undefined;
  private unsubscribeExit: (() => void) | undefined;
  private disconnected = false;

  constructor(private readonly host: SSHHostConfig, private readonly runner: SSHInteractiveRunner, private readonly probe?: SSHFingerprintProbe) {}

  async open(sessionID: string, terminalID?: string): Promise<string> {
    await this.connect();
    const type = terminalID ? 'terminal_attach' : 'terminal_open';
    const response = await this.request(type, { sessionID, ...(this.host.remoteWorkspace ? { cwd: this.host.remoteWorkspace } : {}), ...(terminalID ? { terminalID } : {}) });
    const frame = response as RemoteFrame;
    if (frame.type !== (terminalID ? 'terminal_attached' : 'terminal_opened') || typeof frame.terminalID !== 'string' || !frame.terminalID) throw new Error('Remote Terminal Helper returned invalid open response');
    this.terminalID = frame.terminalID;
    return this.terminalID;
  }

  async attach(sessionID: string, terminalID: string, afterSequence = 0): Promise<SSHRemoteTerminalEntry[]> {
    await this.open(sessionID, terminalID);
    return this.read(afterSequence);
  }

  async exec(command: string, timeoutMs?: number): Promise<SSHRemoteTerminalResult> {
    if (!command.trim()) throw new Error('Remote terminal command is required');
    if (!this.terminalID) throw new Error('Remote terminal is not open');
    try {
      const response = await this.request('terminal_exec', { terminalID: this.terminalID, command, timeoutMs: timeoutFor(this.host, timeoutMs) }, timeoutFor(this.host, timeoutMs));
      const frame = response as RemoteFrame;
      const entry = normalizeEntry(frame);
      if (frame.type !== 'terminal_completed' || !entry) throw new Error('Remote Terminal Helper returned invalid command response');
      this.transcript.set(entry.sequence, entry);
      return { ...entry, state: 'completed', retry: 'none' };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (this.disconnected || /disconnected|timed out/i.test(message)) {
        return { sequence: this.nextSequence(), command, stdout: '', stderr: message, exitCode: -1, completedAt: new Date().toISOString(), state: 'indeterminate', retry: 'manual' };
      }
      throw error;
    }
  }

  async read(afterSequence: number): Promise<SSHRemoteTerminalEntry[]> {
    if (!Number.isInteger(afterSequence) || afterSequence < 0) throw new Error('afterSequence must be a non-negative integer');
    if (!this.terminalID) throw new Error('Remote terminal is not open');
    const response = await this.request('terminal_read', { terminalID: this.terminalID, afterSequence });
    const frame = response as RemoteFrame;
    if (frame.type !== 'terminal_read_result' || !Array.isArray(frame.entries)) throw new Error('Remote Terminal Helper returned invalid transcript response');
    const entries = frame.entries.map(normalizeEntry);
    if (entries.some((entry) => !entry)) throw new Error('Remote Terminal Helper returned invalid transcript entry');
    for (const entry of entries as SSHRemoteTerminalEntry[]) this.transcript.set(entry.sequence, entry);
    return [...this.transcript.values()].filter((entry) => entry.sequence > afterSequence).sort((left, right) => left.sequence - right.sequence);
  }

  async close(): Promise<void> {
    const process = this.process;
    if (!process) return;
    try {
      if (this.terminalID && !this.disconnected) await this.request('terminal_close', { terminalID: this.terminalID }, 5_000);
    } catch { /* Closing an already disconnected terminal is intentionally best-effort. */ }
    this.clearConnection();
    await process.close();
  }

  private async connect(): Promise<void> {
    if (this.process && !this.disconnected) return;
    const validation = validateSSHHost(this.host);
    if (!validation.ok) throw new Error(validation.error);
    if (this.probe) {
      const observed = await this.probe(this.host);
      if (!fingerprintMatches(this.host.fingerprint, observed)) throw new Error('SSH Host Key fingerprint changed; connection blocked');
    }
    this.disconnected = false;
    const process = await this.runner.open(buildSSHPersistentTerminalArguments(this.host), timeoutFor(this.host));
    this.process = process;
    this.unsubscribeLine = process.onLine((line) => this.consume(line));
    this.unsubscribeExit = process.onExit((error) => this.markDisconnected(error));
  }

  private request(type: PendingRequest['type'], payload: Record<string, unknown>, timeoutMs = timeoutFor(this.host)): Promise<unknown> {
    const process = this.process;
    if (!process || this.disconnected) return Promise.reject(new Error('SSH terminal is disconnected'));
    const requestID = randomUUID();
    return new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(requestID);
        reject(new Error(`SSH terminal request timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(requestID, { type, resolve, reject, timeout });
      process.write(`${JSON.stringify({ protocolVersion: 1, requestID, type, ...payload })}\n`);
    });
  }

  private consume(line: string): void {
    let frame: RemoteFrame;
    try { frame = JSON.parse(line) as RemoteFrame; } catch { return; }
    if (frame.protocolVersion !== 1 || typeof frame.requestID !== 'string') return;
    const pending = this.pending.get(frame.requestID);
    if (!pending) return;
    this.pending.delete(frame.requestID);
    clearTimeout(pending.timeout);
    if (typeof frame.error === 'string' && frame.error) pending.reject(new Error(frame.error));
    else pending.resolve(frame);
  }

  private markDisconnected(error?: Error): void {
    if (this.disconnected) return;
    this.disconnected = true;
    const reason = error ?? new Error('SSH terminal disconnected');
    for (const [requestID, pending] of this.pending) {
      this.pending.delete(requestID);
      clearTimeout(pending.timeout);
      pending.reject(reason);
    }
  }

  private clearConnection(): void {
    this.unsubscribeLine?.();
    this.unsubscribeExit?.();
    this.unsubscribeLine = undefined;
    this.unsubscribeExit = undefined;
    this.process = undefined;
    this.terminalID = undefined;
  }

  private nextSequence(): number {
    return Math.max(0, ...this.transcript.keys()) + 1;
  }
}
