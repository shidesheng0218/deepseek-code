import { describe, expect, test } from 'vitest';
import { buildSSHArguments, fingerprintMatches, SSHRemoteToolHost, validateSSHHost } from '../../src/core/ssh-tool-host';

const host = { id: 'prod', hostname: 'example.test', user: 'deploy', port: 2222, fingerprint: 'SHA256:known', remotePath: '/home/deploy/.local/bin/deepseek-host' };

describe('SSH Tool Host', () => {
  test('requires the configured Host Key fingerprint and builds non-interactive SSH arguments', () => {
    expect(validateSSHHost(host)).toEqual({ ok: true });
    expect(fingerprintMatches('SHA256:known', ' SHA256:known ')).toBe(true);
    expect(fingerprintMatches('SHA256:known', 'SHA256:changed')).toBe(false);
    expect(buildSSHArguments(host)).toEqual([
      '-p', '2222', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
      'deploy@example.test', '/home/deploy/.local/bin/deepseek-host'
    ]);
    expect(validateSSHHost({ ...host, fingerprint: '' })).toMatchObject({ ok: false });
  });

  test('sends only a structured remote tool request and marks a timed-out transport indeterminate', async () => {
    let request = '';
    const remote = new SSHRemoteToolHost(host, {
      run: async (_args, input) => { request = input; return { stdout: JSON.stringify({ protocolVersion: 1, id: 'call-1', ok: true, output: 'ok', indeterminate: false }), stderr: '', timedOut: false, exitCode: 0 }; }
    });
    await expect(remote.execute({ id: 'call-1', sessionID: 's1', tool: 'inspect_git', arguments: {} })).resolves.toEqual({ ok: true, output: 'ok', indeterminate: false });
    expect(JSON.parse(request)).toMatchObject({ protocolVersion: 1, id: 'call-1', sessionID: 's1', tool: 'inspect_git', arguments: '{}' });

    const timeoutRemote = new SSHRemoteToolHost(host, { run: async () => ({ stdout: '', stderr: 'timeout', timedOut: true, exitCode: null }) });
    await expect(timeoutRemote.execute({ id: 'call-2', sessionID: 's1', tool: 'run_command', arguments: { command: 'make test' } })).resolves.toEqual({ ok: false, output: 'timeout', indeterminate: true });
  });

  test('blocks a changed Host Key before starting the remote Tool Host', async () => {
    let ran = false;
    const remote = new SSHRemoteToolHost(host, {
      run: async () => { ran = true; return { stdout: '', stderr: '', timedOut: false, exitCode: 0 }; }
    }, async () => 'SHA256:changed');

    await expect(remote.execute({ id: 'call-3', sessionID: 's1', tool: 'inspect_git', arguments: {} })).resolves.toEqual({ ok: false, output: 'SSH Host Key fingerprint changed; connection blocked', indeterminate: false });
    expect(ran).toBe(false);
  });
});
