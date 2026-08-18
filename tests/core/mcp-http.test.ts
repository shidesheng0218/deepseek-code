import { describe, expect, test, vi } from 'vitest';
import { MCPStreamableHTTPClient } from '../../src/core/mcp-http';

describe('MCP Streamable HTTP client', () => {
  test('initializes, discovers tools/resources/prompts, and calls a tool over JSON-RPC HTTP', async () => {
    const fetchImpl = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { id?: number; method: string; params?: Record<string, unknown> };
      if (request.method === 'notifications/initialized') return new Response(null, { status: 202 });
      const result = request.method === 'initialize' ? { protocolVersion: '2025-03-26', capabilities: {}, serverInfo: { name: 'fixture', version: '1' } }
        : request.method === 'tools/list' ? { tools: [{ name: 'lookup', description: 'lookup', inputSchema: { type: 'object' } }] }
        : request.method === 'resources/list' ? { resources: [{ uri: 'fixture://readme', name: 'README' }] }
        : request.method === 'prompts/list' ? { prompts: [{ name: 'summarize', description: 'summarize' }] }
        : { content: [{ type: 'text', text: String(request.params?.arguments && (request.params.arguments as Record<string, unknown>).name) }] };
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }), { headers: { 'content-type': 'application/json' } });
    });
    const client = new MCPStreamableHTTPClient({ url: 'https://mcp.example.test/mcp', fetchImpl });

    await expect(client.start()).resolves.toEqual([{ name: 'lookup', description: 'lookup', inputSchema: { type: 'object' } }]);
    await expect(client.listResources()).resolves.toEqual([{ uri: 'fixture://readme', name: 'README' }]);
    await expect(client.listPrompts()).resolves.toEqual([{ name: 'summarize', description: 'summarize' }]);
    await expect(client.callTool('lookup', { name: 'DeepSeek' })).resolves.toEqual({ content: [{ type: 'text', text: 'DeepSeek' }] });
  });

  test('accepts JSON-RPC responses delivered as SSE and marks tool catalog dirty after notification', async () => {
    let listed = 0;
    const fetchImpl = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { id?: number; method: string };
      if (request.method === 'initialize') return new Response(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: request.id, result: {} })}\n\n`, { headers: { 'content-type': 'text/event-stream' } });
      if (request.method === 'tools/list') {
        listed += 1;
        return new Response(`data: ${JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: listed === 1 ? 'old' : 'new', inputSchema: { type: 'object' } }] } })}\n\ndata: ${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' })}\n\n`, { headers: { 'content-type': 'text/event-stream' } });
      }
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [] } }), { headers: { 'content-type': 'application/json' } });
    });
    const client = new MCPStreamableHTTPClient({ url: 'https://mcp.example.test/mcp', fetchImpl });

    await client.start();
    await expect(client.start()).resolves.toEqual([{ name: 'new', inputSchema: { type: 'object' } }]);
  });
});
