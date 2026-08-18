import { describe, expect, test } from 'vitest';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadSSHProjectConfig } from '../../src/core/ssh-config';

describe('project SSH configuration', () => {
  test('loads only explicitly fingerprint-pinned hosts from .deepseek/ssh.json', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-ssh-config-'));
    await mkdir(join(root, '.deepseek'));
    await writeFile(join(root, '.deepseek', 'ssh.json'), JSON.stringify({ hosts: [{ id: 'prod', hostname: 'example.test', user: 'deploy', port: 22, fingerprint: 'SHA256:known', remotePath: '/home/deploy/deepseek-host', remoteWorkspace: '/srv/app' }] }));

    await expect(loadSSHProjectConfig(root)).resolves.toEqual({ hosts: [{ id: 'prod', hostname: 'example.test', user: 'deploy', port: 22, fingerprint: 'SHA256:known', remotePath: '/home/deploy/deepseek-host', remoteWorkspace: '/srv/app' }] });
  });

  test('rejects an SSH host without a pinned fingerprint', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-ssh-config-invalid-'));
    await mkdir(join(root, '.deepseek'));
    await writeFile(join(root, '.deepseek', 'ssh.json'), JSON.stringify({ hosts: [{ id: 'prod', hostname: 'example.test', user: 'deploy', port: 22, fingerprint: '', remotePath: '/home/deploy/deepseek-host' }] }));

    await expect(loadSSHProjectConfig(root)).rejects.toThrow('fingerprint');
  });
});
