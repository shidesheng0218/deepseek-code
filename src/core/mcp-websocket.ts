import type { MCPPromptDefinition, MCPResourceDefinition, MCPToolDefinition } from './mcp-stdio';

export interface MCPWebSocketLike {
  readyState: number;
  send(data: string): void;
  close(): void;
  addEventListener(type: string, listener: (event: unknown) => void): void;
  removeEventListener(type: string, listener: (event: unknown) => void): void;
}

export interface MCPWebSocketConfig {
  url: string;
  timeoutMs?: number;
  maxOutputBytes?: number;
  webSocketFactory?: (url: string) => MCPWebSocketLike;
}

interface JSONRPCMessage { jsonrpc?: string; id?: number; method?: string; result?: unknown; error?: { message?: string } }
type PendingRequest = { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: ReturnType<typeof setTimeout> };

function timeoutFor(config: MCPWebSocketConfig): number { return Math.min(Math.max(config.timeoutMs ?? 30_000, 500), 120_000); }

function socketFactory(config: MCPWebSocketConfig): (url: string) => MCPWebSocketLike {
  if (config.webSocketFactory) return config.webSocketFactory;
  return (url) => {
    if (typeof WebSocket === 'undefined') throw new Error('WebSocket is unavailable in this runtime');
    return new WebSocket(url) as unknown as MCPWebSocketLike;
  };
}

function messageData(event: unknown): string | undefined {
  if (!event || typeof event !== 'object' || !('data' in event)) return undefined;
  const data = (event as { data?: unknown }).data;
  return typeof data === 'string' ? data : undefined;
}

export class MCPWebSocketClient {
  private socket: MCPWebSocketLike | undefined;
  private connecting: Promise<void> | undefined;
  private nextID = 1;
  private initialized = false;
  private toolsDirty = true;
  private tools: MCPToolDefinition[] = [];
  private readonly pending = new Map<number, PendingRequest>();

  constructor(private readonly config: MCPWebSocketConfig) {}

  async start(): Promise<MCPToolDefinition[]> {
    if (!/^wss?:\/\//.test(this.config.url)) throw new Error('MCP WebSocket URL must use ws or wss');
    await this.connect();
    if (this.initialized && !this.toolsDirty) return this.tools;
    if (!this.initialized) {
      await this.request('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'DeepSeek Code', version: '0.1.0' } });
      this.notify('notifications/initialized', {});
      this.initialized = true;
    }
    const result = await this.request('tools/list', {}) as { tools?: unknown };
    this.tools = Array.isArray(result.tools) ? result.tools.filter((tool): tool is MCPToolDefinition => Boolean(tool && typeof tool === 'object' && typeof (tool as MCPToolDefinition).name === 'string' && (tool as MCPToolDefinition).inputSchema && typeof (tool as MCPToolDefinition).inputSchema === 'object')).slice(0, 128) : [];
    this.toolsDirty = false;
    return this.tools;
  }

  async callTool(name: string, argumentsValue: Record<string, unknown>): Promise<unknown> {
    await this.start();
    if (!this.tools.some((tool) => tool.name === name)) throw new Error(`Unknown MCP tool: ${name}`);
    const result = await this.request('tools/call', { name, arguments: argumentsValue });
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP WebSocket tool output exceeded limit');
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
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP WebSocket resource output exceeded limit');
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
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP WebSocket prompt output exceeded limit');
    return result;
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    this.connecting = undefined;
    this.initialized = false;
    this.toolsDirty = true;
    this.tools = [];
    this.failAll(new Error('MCP WebSocket client closed'));
    socket?.close();
  }

  private async connect(): Promise<void> {
    if (this.socket?.readyState === 1) return;
    if (this.connecting) return this.connecting;
    this.connecting = new Promise<void>((resolveConnect, rejectConnect) => {
      const socket = socketFactory(this.config)(this.config.url);
      const cleanup = (): void => {
        socket.removeEventListener('open', onOpen);
        socket.removeEventListener('error', onError);
        clearTimeout(timeout);
      };
      const onOpen = (): void => { cleanup(); this.socket = socket; this.attach(socket); resolveConnect(); };
      const onError = (): void => { cleanup(); rejectConnect(new Error('MCP WebSocket connection failed')); };
      const timeout = setTimeout(() => { cleanup(); socket.close(); rejectConnect(new Error(`MCP WebSocket connection timed out after ${timeoutFor(this.config)}ms`)); }, timeoutFor(this.config));
      socket.addEventListener('open', onOpen);
      socket.addEventListener('error', onError);
    }).finally(() => { this.connecting = undefined; });
    return this.connecting;
  }

  private attach(socket: MCPWebSocketLike): void {
    socket.addEventListener('message', (event) => this.consume(messageData(event)));
    socket.addEventListener('close', () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.initialized = false;
      this.toolsDirty = true;
      this.tools = [];
      this.failAll(new Error('MCP WebSocket disconnected'));
    });
    socket.addEventListener('error', () => {
      if (this.socket === socket) this.failAll(new Error('MCP WebSocket transport error'));
    });
  }

  private request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const socket = this.socket;
    if (!socket || socket.readyState !== 1) return Promise.reject(new Error('MCP WebSocket is not connected'));
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.pending.delete(id); reject(new Error(`MCP WebSocket request timed out: ${method}`)); }, timeoutFor(this.config));
      this.pending.set(id, { resolve, reject, timeout });
      socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }

  private notify(method: string, params: Record<string, unknown>): void {
    if (this.socket?.readyState === 1) this.socket.send(JSON.stringify({ jsonrpc: '2.0', method, params }));
  }

  private consume(data: string | undefined): void {
    if (!data) return;
    let message: JSONRPCMessage;
    try { message = JSON.parse(data) as JSONRPCMessage; } catch { return; }
    if (message.method === 'notifications/tools/list_changed') { this.toolsDirty = true; this.tools = []; return; }
    if (typeof message.id !== 'number') return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timeout);
    if (message.error) pending.reject(new Error(message.error.message ?? 'MCP WebSocket request failed'));
    else pending.resolve(message.result);
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) { clearTimeout(pending.timeout); pending.reject(error); }
    this.pending.clear();
  }
}
