import { readFile, realpath } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';

export interface MCPServerConfig {
  name: string;
  command?: string;
  args: string[];
  env?: Record<string, string>;
  cwd: string;
  url?: string;
  headers?: Record<string, string>;
  transport?: 'streamable-http' | 'websocket';
  authEnv?: string;
}

export async function loadMCPServerConfigs(workspacePath: string, projectRoot = workspacePath): Promise<MCPServerConfig[]> {
  const root = await realpath(projectRoot);
  const workspace = await realpath(workspacePath);
  if (relative(root, workspace).startsWith('..')) throw new Error('Workspace is outside project root');
  const directories: string[] = [];
  for (let current = workspace; ; current = dirname(current)) {
    directories.unshift(current);
    if (current === root) break;
  }
  const merged = new Map<string, MCPServerConfig>();
  for (const directory of directories) {
    try {
      const raw = JSON.parse(await readFile(resolve(directory, '.mcp.json'), 'utf8')) as { mcpServers?: Record<string, unknown> };
      for (const [name, value] of Object.entries(raw.mcpServers ?? {})) {
        if (!value || typeof value !== 'object') continue;
        const server = value as Record<string, unknown>;
        const args = Array.isArray(server.args) ? server.args.filter((arg): arg is string => typeof arg === 'string') : [];
        let env: Record<string, string> | undefined;
        if (server.env && typeof server.env === 'object') {
          env = Object.fromEntries(Object.entries(server.env as Record<string, unknown>).filter(([, item]) => typeof item === 'string').map(([key, item]) => [key, item as string]));
        }
        if (typeof server.url === 'string' && /^(https?|wss?):\/\//.test(server.url)) {
          const headers = server.headers && typeof server.headers === 'object' ? Object.fromEntries(Object.entries(server.headers as Record<string, unknown>).filter(([key, item]) => typeof item === 'string' && !/authorization|cookie|token|secret|api[-_]?key/i.test(key)).map(([key, item]) => [key, item as string])) : undefined;
          const authEnv = typeof server.authEnv === 'string' && /^[A-Z_][A-Z0-9_]*$/.test(server.authEnv) ? server.authEnv : undefined;
          const transport = /^wss?:\/\//.test(server.url) ? 'websocket' : 'streamable-http';
          const config: MCPServerConfig = { name, args, cwd: directory, url: server.url, transport, ...(authEnv ? { authEnv } : {}), ...(headers && Object.keys(headers).length ? { headers } : {}) };
          merged.set(name, config);
          continue;
        }
        if (typeof server.command !== 'string' || !server.command.trim()) continue;
        const config: MCPServerConfig = { name, command: server.command, args, cwd: directory };
        if (env) config.env = env;
        merged.set(name, config);
      }
    } catch { /* MCP configuration is optional and invalid files stay inert. */ }
  }
  return [...merged.values()].slice(0, 32);
}
