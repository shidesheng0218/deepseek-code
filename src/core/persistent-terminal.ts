import { randomUUID } from 'node:crypto';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

export interface TerminalTranscriptEntry {
  sequence: number;
  command: string;
  stdout: string;
  stderr: string;
  exitCode: number;
  completedAt: string;
}

interface PendingCommand {
  marker: string;
  command: string;
  stdout: string;
  stderr: string;
  resolve: (entry: TerminalTranscriptEntry) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

export class PersistentTerminal {
  private readonly process: ChildProcessWithoutNullStreams;
  private readonly transcript: TerminalTranscriptEntry[] = [];
  private pending: PendingCommand | undefined;
  private tail: Promise<void> = Promise.resolve();
  private sequence = 0;
  private closed = false;

  constructor(options: { cwd: string; shell?: string }) {
    this.process = spawn(options.shell ?? '/bin/zsh', ['-s'], { cwd: options.cwd, stdio: 'pipe' });
    this.process.stdout.setEncoding('utf8');
    this.process.stderr.setEncoding('utf8');
    this.process.stdout.on('data', (chunk: string) => this.consume('stdout', chunk));
    this.process.stderr.on('data', (chunk: string) => this.consume('stderr', chunk));
    this.process.once('exit', (code) => this.failPending(new Error(`Terminal exited unexpectedly (${code ?? 'signal'})`)));
  }

  async exec(command: string, timeoutMs = 120_000): Promise<TerminalTranscriptEntry> {
    if (!command.trim()) throw new Error('Terminal command is required');
    if (this.closed) throw new Error('Terminal is closed');
    let resolveEntry: (entry: TerminalTranscriptEntry) => void = () => undefined;
    let rejectEntry: (error: Error) => void = () => undefined;
    const result = new Promise<TerminalTranscriptEntry>((resolve, reject) => { resolveEntry = resolve; rejectEntry = reject; });
    this.tail = this.tail.then(() => new Promise<void>((resolve) => {
      const marker = `__DEEPSEEK_TERMINAL_${randomUUID()}__`;
      const timeout = setTimeout(() => {
        if (!this.pending || this.pending.marker !== marker) return;
        const pending = this.pending;
        this.pending = undefined;
        pending.reject(new Error(`Terminal command timed out after ${timeoutMs}ms`));
        resolve();
      }, timeoutMs);
      this.pending = { marker, command, stdout: '', stderr: '', resolve: (entry) => { resolveEntry(entry); resolve(); }, reject: (error) => { rejectEntry(error); resolve(); }, timeout };
      this.process.stdin.write(`{ ${command}\n}; __deepseek_status=$?; printf '\\n${marker}:%s\\n' "$__deepseek_status"\n`);
    })).catch(() => undefined);
    return result;
  }

  read(afterSequence: number): TerminalTranscriptEntry[] {
    return this.transcript.filter((entry) => entry.sequence > afterSequence);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.process.stdin.end('exit\n');
    await new Promise<void>((resolve) => this.process.once('exit', () => resolve()));
  }

  private consume(stream: 'stdout' | 'stderr', chunk: string): void {
    const pending = this.pending;
    if (!pending) return;
    if (stream === 'stderr') { pending.stderr += chunk; return; }
    pending.stdout += chunk;
    const expression = new RegExp(`\\n${pending.marker}:(\\d+)\\n`);
    const match = expression.exec(pending.stdout);
    if (!match) return;
    const status = Number(match[1]);
    pending.stdout = pending.stdout.slice(0, match.index);
    clearTimeout(pending.timeout);
    this.pending = undefined;
    const entry: TerminalTranscriptEntry = { sequence: ++this.sequence, command: pending.command, stdout: pending.stdout, stderr: pending.stderr, exitCode: status, completedAt: new Date().toISOString() };
    this.transcript.push(entry);
    pending.resolve(entry);
  }

  private failPending(error: Error): void {
    if (!this.pending) return;
    const pending = this.pending;
    this.pending = undefined;
    clearTimeout(pending.timeout);
    pending.reject(error);
  }
}
