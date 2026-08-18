import { describe, expect, test } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runReadOnlyWorker } from '../../src/core/worker-runtime';

describe('read-only worker runtime', () => {
  test('explore worker returns bounded workspace evidence without changing files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-worker-'));
    await writeFile(join(root, 'README.md'), '# Fixture');
    const result = await runReadOnlyWorker({ workerID: 'worker-1', type: 'explore', projectPath: root });

    expect(result.state).toBe('completed');
    expect(result.evidence.some((item) => item.path === 'README.md')).toBe(true);
    expect(result.summary).toContain('README.md');
  });
});
