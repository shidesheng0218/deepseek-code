import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

export interface MCPToolDefinition {
  name: string;
  description?: string;
  inputSchema: Record<string, unknown>;
}

export interface MCPResourceDefinition { uri: string; name?: string; description?: string; mimeType?: string }
export interface MCPPromptDefinition { name: string; description?: string; arguments?: Array<Record<string, unknown>> }

export interface MCPStdioConfig {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  maxOutputBytes?: number;
}

interface JSONRPCResponse { jsonrpc?: string; id?: number; method?: string; result?: unknown; error?: { code?: number; message?: string; data?: unknown } }

export class MCPStdioClient {
  private process: ChildProcessWithoutNullStreams | undefined;
  private nextID = 1;
  private buffer = '';
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: ReturnType<typeof setTimeout> }>();
  private tools: MCPToolDefinition[] = [];
  private toolsDirty = true;
  private initialized = false;
  private startPromise: Promise<MCPToolDefinition[]> | undefined;

  constructor(private readonly config: MCPStdioConfig) {}

  async start(): Promise<MCPToolDefinition[]> {
    if (this.startPromise) return this.startPromise;
    this.startPromise = this.startInternal().finally(() => { this.startPromise = undefined; });
    return this.startPromise;
  }

  private async startInternal(): Promise<MCPToolDefinition[]> {
    if (this.process && this.initialized && !this.toolsDirty) return this.tools;
    if (!this.config.command.trim() || this.config.command.includes('\0')) throw new Error('Invalid MCP command');
    const env = { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '', ...(this.config.env ?? {}) };
    if (!this.process) this.spawnProcess(env);
    try {
      if (!this.initialized) {
        await this.request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'DeepSeek Code', version: '0.1.0' } });
        this.notify('notifications/initialized', {});
        this.initialized = true;
      }
      if (this.toolsDirty) {
        const result = await this.request('tools/list', {}) as { tools?: MCPToolDefinition[] };
        this.tools = (result.tools ?? []).filter((tool) => typeof tool?.name === 'string').slice(0, 128);
        this.toolsDirty = false;
      }
    } catch (error) {
      const process = this.process;
      this.process = undefined;
      this.initialized = false;
      this.toolsDirty = true;
      this.tools = [];
      if (process) process.kill('SIGTERM');
      throw error;
    }
    return this.tools;
  }

  private spawnProcess(env: NodeJS.ProcessEnv): void {
    const child = spawn(this.config.command, this.config.args ?? [], { cwd: this.config.cwd, env, stdio: 'pipe' });
    this.process = child;
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => this.consume(chunk));
    child.stderr.resume();
    child.once('exit', (code) => {
      if (this.process !== child) return;
      this.process = undefined;
      this.initialized = false;
      this.toolsDirty = true;
      this.tools = [];
      this.failAll(new Error(`MCP server exited (${code ?? 'signal'})`));
    });
  }

  async callTool(name: string, argumentsValue: Record<string, unknown>): Promise<unknown> {
    await this.start();
    if (this.toolsDirty) await this.start();
    if (!this.tools.some((tool) => tool.name === name)) throw new Error(`Unknown MCP tool: ${name}`);
    const result = await this.request('tools/call', { name, arguments: argumentsValue });
    const serialized = JSON.stringify(result);
    if (serialized.length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP tool output exceeded limit');
    return result;
  }

  async listResources(): Promise<MCPResourceDefinition[]> {
    await this.start();
    const result = await this.request('resources/list', {}) as { resources?: unknown };
    return Array.isArray(result.resources) ? result.resources.filter((value): value is MCPResourceDefinition => Boolean(value && typeof value === 'object' && typeof (value as MCPResourceDefinition).uri === 'string')).slice(0, 256) : [];
  }

  async readResource(uri: string): Promise<unknown> {
    if (!uri.trim()) throw new Error('MCP resource URI is required');
    await this.start();
    const result = await this.request('resources/read', { uri });
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP resource output exceeded limit');
    return result;
  }

  async listPrompts(): Promise<MCPPromptDefinition[]> {
    await this.start();
    const result = await this.request('prompts/list', {}) as { prompts?: unknown };
    return Array.isArray(result.prompts) ? result.prompts.filter((value): value is MCPPromptDefinition => Boolean(value && typeof value === 'object' && typeof (value as MCPPromptDefinition).name === 'string')).slice(0, 128) : [];
  }

  async getPrompt(name: string, argumentsValue: Record<string, unknown> = {}): Promise<unknown> {
    if (!name.trim()) throw new Error('MCP prompt name is required');
    await this.start();
    const result = await this.request('prompts/get', { name, arguments: argumentsValue });
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP prompt output exceeded limit');
    return result;
  }

  async close(): Promise<void> {
    if (!this.process) return;
    const process = this.process;
    this.process = undefined;
    this.initialized = false;
    this.toolsDirty = true;
    this.tools = [];
    this.failAll(new Error('MCP client closed'));
    process.kill('SIGTERM');
    await new Promise<void>((resolve) => process.once('exit', () => resolve()));
  }

  private request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = this.nextID++;
    const timeoutMs = Math.min(Math.max(this.config.timeoutMs ?? 30_000, 500), 120_000);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.pending.delete(id); reject(new Error(`MCP request timed out: ${method}`)); }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  private notify(method: string, params: Record<string, unknown>): void { this.write({ jsonrpc: '2.0', method, params }); }

  private write(value: Record<string, unknown>): void {
    if (!this.process?.stdin.writable) throw new Error('MCP server stdin is unavailable');
    this.process.stdin.write(`${JSON.stringify(value)}\n`);
  }

  private consume(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > (this.config.maxOutputBytes ?? 200_000) * 2) { this.failAll(new Error('MCP server output exceeded limit')); return; }
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() ?? '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let message: JSONRPCResponse;
      try { message = JSON.parse(line) as JSONRPCResponse; } catch { continue; }
      if (message.method === 'notifications/tools/list_changed') {
        this.toolsDirty = true;
        this.tools = [];
        continue;
      }
      if (typeof message.id !== 'number') continue;
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) pending.reject(new Error(message.error.message ?? 'MCP request failed'));
      else pending.resolve(message.result);
    }
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(error); }
    this.pending.clear();
  }
}
