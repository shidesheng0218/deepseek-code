import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { validateSSHHost, type SSHHostConfig } from './ssh-tool-host';

export interface SSHProjectConfig { hosts: SSHHostConfig[] }

export async function loadSSHProjectConfig(projectPath: string): Promise<SSHProjectConfig> {
  let raw: string;
  try { raw = await readFile(join(projectPath, '.deepseek', 'ssh.json'), 'utf8'); }
  catch { return { hosts: [] }; }
  let parsed: unknown;
  try { parsed = JSON.parse(raw); }
  catch { throw new Error('Invalid .deepseek/ssh.json'); }
  if (!parsed || typeof parsed !== 'object' || !Array.isArray((parsed as { hosts?: unknown }).hosts)) throw new Error('.deepseek/ssh.json requires a hosts array');
  const hosts: SSHHostConfig[] = [];
  for (const candidate of (parsed as { hosts: unknown[] }).hosts.slice(0, 32)) {
    if (!candidate || typeof candidate !== 'object') throw new Error('Invalid SSH host configuration');
    const value = candidate as Record<string, unknown>;
    const host: SSHHostConfig = {
      id: String(value.id ?? ''),
      hostname: String(value.hostname ?? ''),
      user: String(value.user ?? ''),
      port: Number(value.port ?? 0),
      fingerprint: String(value.fingerprint ?? ''),
      remotePath: String(value.remotePath ?? ''),
      ...(typeof value.timeoutMs === 'number' ? { timeoutMs: value.timeoutMs } : {})
    };
    const validation = validateSSHHost(host);
    if (!validation.ok) throw new Error(`Invalid SSH host ${host.id || '<unknown>'}: ${validation.error}`);
    hosts.push(host);
  }
  return { hosts };
}
