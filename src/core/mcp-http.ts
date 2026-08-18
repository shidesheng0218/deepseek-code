import type { MCPPromptDefinition, MCPResourceDefinition, MCPToolDefinition } from './mcp-stdio';

export interface MCPHTTPConfig {
  url: string;
  headers?: Record<string, string>;
  timeoutMs?: number;
  maxOutputBytes?: number;
  fetchImpl?: typeof fetch;
  tokenProvider?: () => Promise<string | undefined>;
}

interface JSONRPCMessage { jsonrpc?: string; id?: number; method?: string; result?: unknown; error?: { message?: string } }

function timeoutFor(config: MCPHTTPConfig): number { return Math.min(Math.max(config.timeoutMs ?? 30_000, 500), 120_000); }

function parseMessages(body: string, contentType: string): JSONRPCMessage[] {
  if (contentType.includes('application/json') || !contentType.includes('text/event-stream')) {
    try { return [JSON.parse(body) as JSONRPCMessage]; } catch { throw new Error('MCP HTTP returned invalid JSON'); }
  }
  const messages: JSONRPCMessage[] = [];
  let data: string[] = [];
  const flush = (): void => {
    if (!data.length) return;
    const value = data.join('\n').trim();
    data = [];
    if (!value || value === '[DONE]') return;
    try { messages.push(JSON.parse(value) as JSONRPCMessage); } catch { /* Ignore non-JSON SSE comments. */ }
  };
  for (const line of body.split(/\r?\n/)) {
    if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
    else if (!line.trim()) flush();
  }
  flush();
  if (!messages.length) throw new Error('MCP HTTP returned an empty SSE response');
  return messages;
}

export class MCPStreamableHTTPClient {
  private nextID = 1;
  private initialized = false;
  private toolsDirty = true;
  private tools: MCPToolDefinition[] = [];
  private catalogChangedDuringRequest = false;

  constructor(private readonly config: MCPHTTPConfig) {}

  async start(): Promise<MCPToolDefinition[]> {
    if (!this.config.url.startsWith('https://') && !this.config.url.startsWith('http://')) throw new Error('MCP HTTP URL must use http or https');
    if (this.initialized && !this.toolsDirty) return this.tools;
    if (!this.initialized) {
      await this.request('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'DeepSeek Code', version: '0.1.0' } });
      await this.notify('notifications/initialized', {});
      this.initialized = true;
    }
    this.catalogChangedDuringRequest = false;
    const result = await this.request('tools/list', {}) as { tools?: unknown };
    this.tools = Array.isArray(result.tools) ? result.tools.filter((tool): tool is MCPToolDefinition => Boolean(tool && typeof tool === 'object' && typeof (tool as MCPToolDefinition).name === 'string' && (tool as MCPToolDefinition).inputSchema && typeof (tool as MCPToolDefinition).inputSchema === 'object')).slice(0, 128) : [];
    this.toolsDirty = this.catalogChangedDuringRequest;
    return this.tools;
  }

  async listResources(): Promise<MCPResourceDefinition[]> {
    await this.start();
    const result = await this.request('resources/list', {}) as { resources?: unknown };
    return Array.isArray(result.resources) ? result.resources.filter((value): value is MCPResourceDefinition => Boolean(value && typeof value === 'object' && typeof (value as MCPResourceDefinition).uri === 'string')).slice(0, 256) : [];
  }

  async listPrompts(): Promise<MCPPromptDefinition[]> {
    await this.start();
    const result = await this.request('prompts/list', {}) as { prompts?: unknown };
    return Array.isArray(result.prompts) ? result.prompts.filter((value): value is MCPPromptDefinition => Boolean(value && typeof value === 'object' && typeof (value as MCPPromptDefinition).name === 'string')).slice(0, 128) : [];
  }

  async callTool(name: string, argumentsValue: Record<string, unknown>): Promise<unknown> {
    await this.start();
    if (!this.tools.some((tool) => tool.name === name)) throw new Error(`Unknown MCP tool: ${name}`);
    const result = await this.request('tools/call', { name, arguments: argumentsValue });
    if (JSON.stringify(result).length > (this.config.maxOutputBytes ?? 200_000)) throw new Error('MCP HTTP tool output exceeded limit');
    return result;
  }

  async close(): Promise<void> { this.initialized = false; this.toolsDirty = true; this.tools = []; }

  private async notify(method: string, params: Record<string, unknown>): Promise<void> {
    const response = await this.fetchJSON({ jsonrpc: '2.0', method, params }, true);
    this.consumeNotifications(response.messages);
  }

  private async request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = this.nextID++;
    const response = await this.fetchJSON({ jsonrpc: '2.0', id, method, params });
    this.consumeNotifications(response.messages);
    const message = response.messages.find((candidate) => candidate.id === id);
    if (!message) throw new Error(`MCP HTTP response did not match request: ${method}`);
    if (message.error) throw new Error(message.error.message ?? 'MCP HTTP request failed');
    return message.result;
  }

  private consumeNotifications(messages: JSONRPCMessage[]): void {
    if (messages.some((message) => message.method === 'notifications/tools/list_changed')) { this.catalogChangedDuringRequest = true; this.toolsDirty = true; this.tools = []; }
  }

  private async fetchJSON(payload: Record<string, unknown>, allowEmpty = false): Promise<{ messages: JSONRPCMessage[] }> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutFor(this.config));
    try {
      const fetchImpl = this.config.fetchImpl ?? fetch;
      const token = await this.config.tokenProvider?.();
      const response = await fetchImpl(this.config.url, {
        method: 'POST',
        headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json', ...(this.config.headers ?? {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
        body: JSON.stringify(payload),
        signal: controller.signal
      });
      if (response.status === 401 || response.status === 403) throw new Error(`MCP HTTP authentication failed with status ${response.status}`);
      if (!response.ok) throw new Error(`MCP HTTP request failed with status ${response.status}`);
      const body = await response.text();
      if (!body.trim() && allowEmpty) return { messages: [] };
      return { messages: parseMessages(body, response.headers.get('content-type') ?? '') };
    } catch (error) {
      if (controller.signal.aborted) throw new Error(`MCP HTTP request timed out after ${timeoutFor(this.config)}ms`);
      throw error;
    } finally { clearTimeout(timer); }
  }
}
