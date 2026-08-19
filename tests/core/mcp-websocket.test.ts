import { describe, expect, test } from 'vitest';
import { MCPWebSocketClient, type MCPWebSocketLike } from '../../src/core/mcp-websocket';

class FakeSocket implements MCPWebSocketLike {
  readyState = 0;
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>();
  constructor() { queueMicrotask(() => { this.readyState = 1; this.emit('open', {}); }); }
  addEventListener(type: string, listener: (event: unknown) => void): void { const set = this.listeners.get(type) ?? new Set(); set.add(listener); this.listeners.set(type, set); }
  removeEventListener(type: string, listener: (event: unknown) => void): void { this.listeners.get(type)?.delete(listener); }
  send(value: string): void {
    const request = JSON.parse(value) as { id?: number; method: string; params?: Record<string, unknown> };
    const result = request.method === 'initialize' ? { capabilities: {} } : request.method === 'tools/list' ? { tools: [{ name: 'hello', inputSchema: { type: 'object' } }] } : request.method === 'resources/list' ? { resources: [{ uri: 'fixture://readme' }] } : request.method === 'prompts/list' ? { prompts: [{ name: 'summarize' }] } : request.method === 'tools/call' ? { content: [{ type: 'text', text: 'hello' }] } : { contents: [{ uri: String(request.params?.uri), text: 'readme' }] };
    queueMicrotask(() => this.emit('message', { data: JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) }));
  }
  close(): void { this.readyState = 3; this.emit('close', {}); }
  private emit(type: string, event: unknown): void { for (const listener of this.listeners.get(type) ?? []) listener(event); }
}

describe('MCP WebSocket client', () => {
  test('uses the same tool/resource/prompt contract as HTTP and stdio transports', async () => {
    const client = new MCPWebSocketClient({ url: 'wss://mcp.example.test/mcp', webSocketFactory: () => new FakeSocket() });
    await expect(client.start()).resolves.toEqual([{ name: 'hello', inputSchema: { type: 'object' } }]);
    await expect(client.listResources()).resolves.toEqual([{ uri: 'fixture://readme' }]);
    await expect(client.readResource('fixture://readme')).resolves.toEqual({ contents: [{ uri: 'fixture://readme', text: 'readme' }] });
    await expect(client.listPrompts()).resolves.toEqual([{ name: 'summarize' }]);
    await expect(client.callTool('hello', {})).resolves.toEqual({ content: [{ type: 'text', text: 'hello' }] });
    await client.close();
  });
});
