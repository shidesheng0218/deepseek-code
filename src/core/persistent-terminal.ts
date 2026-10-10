import { randomUUID } from 'node:crypto';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { statSync } from 'node:fs';

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

/** close() 等待 shell 自行退出的上限；超过就 SIGTERM，避免调用方永久挂起。 */
const CLOSE_TIMEOUT_MS = 2_000;

function assertUsableDirectory(cwd: string): void {
  let stats: ReturnType<typeof statSync>;
  try {
    stats = statSync(cwd);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Terminal working directory is unavailable: ${detail}`);
  }
  if (!stats.isDirectory()) throw new Error(`Terminal working directory is not a directory: ${cwd}`);
}

export class PersistentTerminal {
  private readonly process: ChildProcessWithoutNullStreams;
  private readonly transcript: TerminalTranscriptEntry[] = [];
  private pending: PendingCommand | undefined;
  private tail: Promise<void> = Promise.resolve();
  private sequence = 0;
  private closed = false;
  private spawnError: Error | undefined;

  constructor(options: { cwd: string; shell?: string }) {
    // 先同步校验工作目录：项目目录被删除/移动时，spawn 的 ENOENT 只在子进程上异步
    // 派发 'error'，调用方拿不到可 catch 的错误。提前抛错让它变成一条正常的失败
    // 响应，而不是一条杀死整个 sidecar 的未捕获异常。
    assertUsableDirectory(options.cwd);
    this.process = spawn(options.shell ?? '/bin/zsh', ['-s'], { cwd: options.cwd, stdio: 'pipe' });
    this.process.stdout.setEncoding('utf8');
    this.process.stderr.setEncoding('utf8');
    this.process.stdout.on('data', (chunk: string) => this.consume('stdout', chunk));
    this.process.stderr.on('data', (chunk: string) => this.consume('stderr', chunk));
    // spawn 失败与 stdin 断管都以 'error' 事件的形式出现；没有监听器时它们会变成
    // 未捕获异常，直接杀掉 sidecar——同一进程里所有会话一起陪葬。
    this.process.on('error', (error: Error) => {
      this.spawnError = this.spawnError ?? error;
      this.failPending(new Error(`Terminal failed to start (${error.message})`));
    });
    this.process.stdin.on('error', (error: Error) => {
      this.spawnError = this.spawnError ?? error;
      this.failPending(new Error(`Terminal input stream failed (${error.message})`));
    });
    this.process.once('exit', (code) => this.failPending(new Error(`Terminal exited unexpectedly (${code ?? 'signal'})`)));
  }

  async exec(command: string, timeoutMs = 120_000): Promise<TerminalTranscriptEntry> {
    if (!command.trim()) throw new Error('Terminal command is required');
    if (this.closed) throw new Error('Terminal is closed');
    // shell 已经起不来（或 stdin 已断）时不要再排队：直接给出原始原因，
    // 否则命令会一直等到超时，调用方只看到一句含糊的 timeout。
    if (this.spawnError) throw new Error(`Terminal is not usable: ${this.spawnError.message}`);
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
      try {
        this.process.stdin.write(`{ ${command}\n}; __deepseek_status=$?; printf '\\n${marker}:%s\\n' "$__deepseek_status"\n`);
      } catch (error) {
        // 管道被对端关掉时 write 是同步抛错；走 failPending 统一收尾，
        // 让它变成一条正常的命令失败，而不是未捕获异常。
        this.failPending(new Error(`Terminal input stream failed (${error instanceof Error ? error.message : String(error)})`));
      }
    })).catch(() => undefined);
    return result;
  }

  read(afterSequence: number): TerminalTranscriptEntry[] {
    return this.transcript.filter((entry) => entry.sequence > afterSequence);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    // 子进程可能已经退出（用户在终端面板敲了 exit、shell 崩溃、spawn 失败）。
    // 此时 'exit' 事件早已派发过，再 once('exit') 会永久挂起——而调用方
    // （memory-monitor 的资源清理）正 await 在这里，整张资源表都会被卡住。
    if (this.process.exitCode !== null || this.process.signalCode !== null) return;
    try {
      this.process.stdin.end('exit\n');
    } catch {
      // stdin 已关闭时 end() 会同步抛错；下面照样等待退出或超时。
    }
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => { this.process.kill('SIGTERM'); resolve(); }, CLOSE_TIMEOUT_MS);
      this.process.once('exit', () => { clearTimeout(timer); resolve(); });
    });
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
