import { readFile, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { WorkspacePatchService } from '../../src/core/tools/workspace-patch';

describe('workspace patch service', () => {
  test('applies a content change atomically and restores the checkpoint', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-patch-'));
    const checkpointRoot = await mkdtemp(join(tmpdir(), 'deepseek-checkpoints-'));
    await writeFile(join(root, 'app.ts'), 'export const value = 1;\n');
    const service = new WorkspacePatchService({ checkpointRoot });

    const result = await service.apply(root, [{ path: 'app.ts', content: 'export const value = 2;\n' }], 'update app value');
    expect(await readFile(join(root, 'app.ts'), 'utf8')).toBe('export const value = 2;\n');
    expect(result.changedFiles).toEqual(['app.ts']);

    await service.restore(root, result.checkpointId);
    expect(await readFile(join(root, 'app.ts'), 'utf8')).toBe('export const value = 1;\n');
  });

  test('rejects a stale optimistic hash instead of overwriting a user edit', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-patch-'));
    const checkpointRoot = await mkdtemp(join(tmpdir(), 'deepseek-checkpoints-'));
    await writeFile(join(root, 'app.ts'), 'user version\n');
    const service = new WorkspacePatchService({ checkpointRoot });

    await expect(service.apply(root, [{ path: 'app.ts', content: 'agent version\n', expectedHash: 'stale' }], 'stale edit')).rejects.toThrow('hash mismatch');
  });
});
