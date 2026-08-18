import { describe, expect, test } from 'vitest';
import { mkdir, mkdtemp, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadMCPServerConfigs } from '../../src/core/mcp-config';

describe('MCP configuration', () => {
  test('loads stdio servers without executing them', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-mcp-'));
    await mkdir(join(root, 'nested'));
    await writeFile(join(root, '.mcp.json'), JSON.stringify({ mcpServers: { fixture: { command: 'node', args: ['server.js'], env: { FIXTURE: '1' } } } }));
    const configs = await loadMCPServerConfigs(join(root, 'nested'), root);
    expect(configs).toEqual([{ name: 'fixture', command: 'node', args: ['server.js'], env: { FIXTURE: '1' }, cwd: await realpath(root) }]);
  });

  test('loads streamable HTTP servers without starting network connections', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-mcp-http-'));
    await writeFile(join(root, '.mcp.json'), JSON.stringify({ mcpServers: { docs: { url: 'https://mcp.example.test/mcp', headers: { 'x-project': 'fixture' } } } }));
    const configs = await loadMCPServerConfigs(root, root);
    expect(configs).toEqual([{ name: 'docs', args: [], cwd: await realpath(root), url: 'https://mcp.example.test/mcp', headers: { 'x-project': 'fixture' }, transport: 'streamable-http' }]);
  });
});
