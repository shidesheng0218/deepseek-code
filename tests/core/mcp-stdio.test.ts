import { describe, expect, test } from 'vitest';
import { MCPStdioClient } from '../../src/core/mcp-stdio';

describe('MCP stdio client', () => {
  test('initializes, discovers tools and calls a tool over JSON-RPC', async () => {
    const server = `
      let buffer = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => { buffer += chunk; const lines = buffer.split('\\n'); buffer = lines.pop() || ''; for (const line of lines) { if (!line.trim()) continue; const request = JSON.parse(line); if (request.method === 'initialize') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'fixture', version: '1' } } }) + '\\n'); else if (request.method === 'tools/list') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: 'hello', description: 'say hello', inputSchema: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] } }] } }) + '\\n'); else if (request.method === 'tools/call') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text: 'Hello ' + request.params.arguments.name }] } }) + '\\n'); } });
    `;
    const client = new MCPStdioClient({ command: process.execPath, args: ['-e', server] });
    try {
      const tools = await client.start();
      expect(tools[0]?.name).toBe('hello');
      await expect(client.callTool('hello', { name: 'DeepSeek' })).resolves.toEqual({ content: [{ type: 'text', text: 'Hello DeepSeek' }] });
    } finally {
      await client.close();
    }
  });
});
