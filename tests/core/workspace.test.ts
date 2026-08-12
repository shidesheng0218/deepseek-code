import { mkdtemp, mkdir, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { readWorkspaceFile, resolveWorkspacePath } from '../../src/core/tools/workspace';

describe('workspace isolation', () => {
  test('rejects parent path traversal', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-workspace-'));
    await expect(resolveWorkspacePath(root, '../outside.txt')).rejects.toThrow('outside the workspace');
  });

  test('rejects symlinks that escape the workspace', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-workspace-'));
    const outside = await mkdtemp(join(tmpdir(), 'deepseek-outside-'));
    await writeFile(join(outside, 'secret.txt'), 'secret');
    await symlink(join(outside, 'secret.txt'), join(root, 'secret-link'));

    await expect(resolveWorkspacePath(root, 'secret-link')).rejects.toThrow('outside the workspace');
  });

  test('reads bounded text with a stable hash', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-workspace-'));
    await mkdir(join(root, 'src'));
    await writeFile(join(root, 'src', 'index.ts'), 'one\ntwo\nthree\n');

    const result = await readWorkspaceFile(root, 'src/index.ts', { startLine: 2, maxLines: 1 });
    expect(result.content).toBe('2: two');
    expect(result.truncated).toBe(true);
    expect(result.sha256).toMatch(/^[a-f0-9]{64}$/);
  });
});
