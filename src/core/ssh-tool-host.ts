import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

export interface SSHHostConfig {
  id: string;
  hostname: string;
  user: string;
  port: number;
  fingerprint: string;
  remotePath: string;
  timeoutMs?: number;
}

export interface SSHRemoteToolInvocation {
  id: string;
  sessionID: string;
  tool: 'read_file' | 'list_directory' | 'search_workspace' | 'inspect_git' | 'apply_patch' | 'run_command';
  arguments: Record<string, unknown>;
}

export interface SSHProcessRunnerResult {
  stdout: string;
  stderr: string;
  timedOut: boolean;
  exitCode: number | null;
}

export interface SSHProcessRunner {
  run(args: string[], input: string, timeoutMs: number): Promise<SSHProcessRunnerResult>;
}

export interface SSHCommandRunner {
  run(executable: string, args: string[], input: string, timeoutMs: number): Promise<SSHProcessRunnerResult>;
}

export type SSHFingerprintProbe = (host: SSHHostConfig) => Promise<string>;

export interface SSHExecutionResult {
  ok: boolean;
  output: string;
  indeterminate: boolean;
}

export function validateSSHHost(host: SSHHostConfig): { ok: true } | { ok: false; error: string } {
  if (!/^[A-Za-z0-9._-]+$/.test(host.id)) return { ok: false, error: 'Invalid SSH host id' };
  if (!host.hostname || /[\s/@\0]/.test(host.hostname)) return { ok: false, error: 'Invalid SSH hostname' };
  if (!/^[A-Za-z0-9._-]+$/.test(host.user)) return { ok: false, error: 'Invalid SSH user' };
  if (!Number.isInteger(host.port) || host.port < 1 || host.port > 65_535) return { ok: false, error: 'Invalid SSH port' };
  if (!/^SHA256:[A-Za-z0-9+/=_-]+$/.test(host.fingerprint.trim())) return { ok: false, error: 'SSH Host Key fingerprint is required' };
  if (!host.remotePath || host.remotePath.includes('\0') || !host.remotePath.startsWith('/')) return { ok: false, error: 'Invalid remote Tool Host path' };
  return { ok: true };
}

export function fingerprintMatches(expected: string, observed: string): boolean {
  return Boolean(expected.trim()) && expected.trim() === observed.trim();
}

export function buildSSHArguments(host: SSHHostConfig): string[] {
  return ['-p', String(host.port), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${host.user}@${host.hostname}`, host.remotePath];
}

function systemCommandRunner(): SSHCommandRunner {
  return {
    run: (executable, args, input, timeoutMs) => new Promise((resolve, reject) => {
      const child: ChildProcessWithoutNullStreams = spawn(executable, args, { stdio: 'pipe' });
      let stdout = '';
      let stderr = '';
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        child.kill('SIGTERM');
        resolve({ stdout, stderr, timedOut: true, exitCode: null });
      }, timeoutMs);
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk: string) => { stdout += chunk; });
      child.stderr.on('data', (chunk: string) => { stderr += chunk; });
      child.once('error', (error) => { if (!settled) { settled = true; clearTimeout(timer); reject(error); } });
      child.once('exit', (code) => { if (!settled) { settled = true; clearTimeout(timer); resolve({ stdout, stderr, timedOut: false, exitCode: code }); } });
      child.stdin.end(input);
    })
  };
}

export function createSystemSSHProcessRunner(): SSHProcessRunner {
  const commands = systemCommandRunner();
  return { run: (args, input, timeoutMs) => commands.run('/usr/bin/ssh', args, input, timeoutMs) };
}

export function createSystemSSHFingerprintProbe(): SSHFingerprintProbe {
  const commands = systemCommandRunner();
  return async (host) => {
    const scan = await commands.run('/usr/bin/ssh-keyscan', ['-p', String(host.port), host.hostname], '', Math.min(host.timeoutMs ?? 60_000, 120_000));
    if (scan.timedOut || scan.exitCode !== 0 || !scan.stdout.trim()) throw new Error(scan.stderr || 'ssh-keyscan failed');
    const fingerprint = await commands.run('/usr/bin/ssh-keygen', ['-lf', '-', '-E', 'sha256'], scan.stdout, Math.min(host.timeoutMs ?? 60_000, 120_000));
    if (fingerprint.timedOut || fingerprint.exitCode !== 0) throw new Error(fingerprint.stderr || 'ssh-keygen fingerprint failed');
    const match = /SHA256:[A-Za-z0-9+/=_-]+/.exec(fingerprint.stdout);
    if (!match) throw new Error('SSH Host Key fingerprint was not returned');
    return match[0];
  };
}

export class SSHRemoteToolHost {
  constructor(private readonly host: SSHHostConfig, private readonly runner: SSHProcessRunner, private readonly probe?: SSHFingerprintProbe) {}

  async execute(invocation: SSHRemoteToolInvocation): Promise<SSHExecutionResult> {
    const validation = validateSSHHost(this.host);
    if (!validation.ok) return { ok: false, output: validation.error, indeterminate: false };
    if (this.probe) {
      try {
        const observed = await this.probe(this.host);
        if (!fingerprintMatches(this.host.fingerprint, observed)) return { ok: false, output: 'SSH Host Key fingerprint changed; connection blocked', indeterminate: false };
      } catch (error) {
        return { ok: false, output: error instanceof Error ? error.message : String(error), indeterminate: false };
      }
    }
    const request = JSON.stringify({ protocolVersion: 1, id: invocation.id, sessionID: invocation.sessionID, tool: invocation.tool, arguments: JSON.stringify(invocation.arguments) });
    const result = await this.runner.run(buildSSHArguments(this.host), `${request}\n`, Math.min(Math.max(this.host.timeoutMs ?? 60_000, 1_000), 600_000));
    if (result.timedOut) return { ok: false, output: result.stderr || result.stdout || 'SSH request timed out', indeterminate: true };
    if (result.exitCode !== 0) return { ok: false, output: result.stderr || result.stdout || `SSH exited with ${result.exitCode ?? 'unknown'}`, indeterminate: true };
    const line = result.stdout.split('\n').map((value) => value.trim()).filter(Boolean).at(-1);
    if (!line) return { ok: false, output: 'Remote Tool Host returned no response', indeterminate: true };
    try {
      const response = JSON.parse(line) as { protocolVersion?: number; id?: string; ok?: boolean; output?: string; indeterminate?: boolean };
      if (response.protocolVersion !== 1 || response.id !== invocation.id || typeof response.ok !== 'boolean' || typeof response.output !== 'string') return { ok: false, output: 'Remote Tool Host returned invalid protocol data', indeterminate: true };
      return { ok: response.ok, output: response.output, indeterminate: response.indeterminate === true };
    } catch {
      return { ok: false, output: 'Remote Tool Host returned invalid JSON', indeterminate: true };
    }
  }
}
