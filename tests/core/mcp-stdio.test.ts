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

  test('refreshes the tool catalog after tools/list_changed notification', async () => {
    const server = `
      let buffer = ''; let lists = 0;
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => { buffer += chunk; const lines = buffer.split('\\n'); buffer = lines.pop() || ''; for (const line of lines) { if (!line.trim()) continue; const request = JSON.parse(line); if (request.method === 'initialize') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: {} }) + '\\n'); else if (request.method === 'tools/list') { lists += 1; process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: lists === 1 ? 'hello' : 'world', inputSchema: { type: 'object' } }] } }) + '\\n'); if (lists === 1) setTimeout(() => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' }) + '\\n'), 5); } else if (request.method === 'tools/call') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text: request.params.name }] } }) + '\\n'); } });
    `;
    const client = new MCPStdioClient({ command: process.execPath, args: ['-e', server] });
    try {
      await client.start();
      await new Promise((resolve) => setTimeout(resolve, 20));
      await expect(client.callTool('world', {})).resolves.toEqual({ content: [{ type: 'text', text: 'world' }] });
    } finally { await client.close(); }
  });

  test('reconnects and rediscovers tools after the MCP process exits', async () => {
    const server = `
      let buffer = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => { buffer += chunk; const lines = buffer.split('\\n'); buffer = lines.pop() || ''; for (const line of lines) { if (!line.trim()) continue; const request = JSON.parse(line); if (request.method === 'initialize') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: {} }) + '\\n'); else if (request.method === 'tools/list') process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: 'hello', inputSchema: { type: 'object' } }] } }) + '\\n'); else if (request.method === 'tools/call') { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text: 'reconnected' }] } }) + '\\n'); setTimeout(() => process.exit(0), 5); } } });
    `;
    const client = new MCPStdioClient({ command: process.execPath, args: ['-e', server] });
    try {
      await client.start();
      await expect(client.callTool('hello', {})).resolves.toEqual({ content: [{ type: 'text', text: 'reconnected' }] });
      await new Promise((resolve) => setTimeout(resolve, 30));
      await expect(client.callTool('hello', {})).resolves.toEqual({ content: [{ type: 'text', text: 'reconnected' }] });
    } finally { await client.close(); }
  });
});
