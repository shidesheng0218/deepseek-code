import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

export interface LSPDiagnostic {
  message: string;
  severity?: number;
  range?: { start: { line: number; character: number }; end: { line: number; character: number } };
  source?: string;
}

export interface LanguageServerConfig {
  command: string;
  args?: string[];
  rootPath: string;
  timeoutMs?: number;
}

interface LSPResponse { id?: number; result?: unknown; error?: { message?: string } }

export class LanguageServerClient {
  private process: ChildProcessWithoutNullStreams | undefined;
  private buffer = '';
  private nextID = 1;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: ReturnType<typeof setTimeout> }>();

  constructor(private readonly config: LanguageServerConfig) {}

  async diagnostics(uri: string, text: string, languageId: string): Promise<LSPDiagnostic[]> {
    await this.start();
    this.notify('textDocument/didOpen', { textDocument: { uri, languageId, version: 1, text } });
    const result = await this.request('textDocument/diagnostic', { textDocument: { uri } }) as { items?: LSPDiagnostic[] };
    return (result.items ?? []).slice(0, 200);
  }

  async close(): Promise<void> {
    if (!this.process) return;
    const process = this.process;
    this.process = undefined;
    this.failAll(new Error('LSP client closed'));
    process.kill('SIGTERM');
    await new Promise<void>((resolve) => process.once('exit', () => resolve()));
  }

  private async start(): Promise<void> {
    if (this.process) return;
    this.process = spawn(this.config.command, this.config.args ?? [], { cwd: this.config.rootPath, env: { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '' }, stdio: 'pipe' });
    this.process.stdout.setEncoding('utf8');
    this.process.stdout.on('data', (chunk: string) => this.consume(chunk));
    this.process.stderr.resume();
    this.process.once('exit', (code) => { this.process = undefined; this.failAll(new Error(`Language server exited (${code ?? 'signal'})`)); });
    await this.request('initialize', { processId: process.pid, rootUri: `file://${this.config.rootPath}`, capabilities: { textDocument: { diagnostic: {} } }, clientInfo: { name: 'DeepSeek Code', version: '0.1.0' } });
    this.notify('initialized', {});
  }

  private request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = this.nextID++;
    const timeoutMs = Math.min(Math.max(this.config.timeoutMs ?? 15_000, 500), 120_000);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.pending.delete(id); reject(new Error(`LSP request timed out: ${method}`)); }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  private notify(method: string, params: Record<string, unknown>): void { this.write({ jsonrpc: '2.0', method, params }); }

  private write(value: Record<string, unknown>): void {
    if (!this.process?.stdin.writable) throw new Error('Language server stdin is unavailable');
    const body = JSON.stringify(value);
    this.process.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  }

  private consume(chunk: string): void {
    this.buffer += chunk;
    while (true) {
      const boundary = this.buffer.indexOf('\r\n\r\n');
      if (boundary === -1) return;
      const header = this.buffer.slice(0, boundary);
      const match = /content-length:\s*(\d+)/i.exec(header);
      if (!match) { this.buffer = this.buffer.slice(boundary + 4); continue; }
      const length = Number(match[1]);
      const start = boundary + 4;
      if (this.buffer.length < start + length) return;
      const text = this.buffer.slice(start, start + length);
      this.buffer = this.buffer.slice(start + length);
      let response: LSPResponse;
      try { response = JSON.parse(text) as LSPResponse; } catch { continue; }
      if (typeof response.id !== 'number') continue;
      const pending = this.pending.get(response.id);
      if (!pending) continue;
      this.pending.delete(response.id);
      clearTimeout(pending.timeout);
      if (response.error) pending.reject(new Error(response.error.message ?? 'LSP request failed'));
      else pending.resolve(response.result);
    }
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(error); }
    this.pending.clear();
  }
}
