import { describe, expect, test } from 'vitest';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
import { runReadOnlyWorker } from '../../src/core/worker-runtime';

const execFile = promisify(execFileCallback);

describe('read-only worker runtime', () => {
  test('explore worker returns bounded workspace evidence without changing files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-worker-'));
    await writeFile(join(root, 'README.md'), '# Fixture');
    const result = await runReadOnlyWorker({ workerID: 'worker-1', type: 'explore', projectPath: root });

    expect(result.state).toBe('completed');
    expect(result.evidence.some((item) => item.path === 'README.md')).toBe(true);
    expect(result.summary).toContain('README.md');
  });

  test('research worker returns query-matched workspace evidence without changing files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-worker-research-'));
    await mkdir(join(root, 'docs'));
    const source = 'Agent runtime uses durable evidence.\n';
    await writeFile(join(root, 'docs', 'architecture.md'), source);
    const result = await runReadOnlyWorker({ workerID: 'worker-2', type: 'research', projectPath: root, query: 'durable evidence' });

    expect(result.state).toBe('completed');
    expect(result.evidence).toContainEqual({ path: 'docs/architecture.md', kind: 'file' });
    expect(result.summary).toContain('durable evidence');
    expect(await readFile(join(root, 'docs', 'architecture.md'), 'utf8')).toBe(source);
  });

  test('CI worker focuses evidence on workflow and build configuration files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-worker-ci-'));
    await mkdir(join(root, '.github', 'workflows'), { recursive: true });
    await writeFile(join(root, '.github', 'workflows', 'ci.yml'), 'name: CI\n');
    await writeFile(join(root, 'package.json'), '{"name":"fixture"}\n');
    await writeFile(join(root, 'README.md'), '# Fixture\n');
    const result = await runReadOnlyWorker({ workerID: 'worker-3', type: 'ci', projectPath: root });

    expect(result.state).toBe('completed');
    expect(result.evidence.map((item) => item.path)).toEqual(expect.arrayContaining(['.github/workflows/ci.yml', 'package.json']));
    expect(result.evidence.map((item) => item.path)).not.toContain('README.md');
  });

  test('review worker reports the current Git Diff without changing it', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-worker-review-'));
    await writeFile(join(root, 'README.md'), '# Before\n');
    await execFile('git', ['init', '--quiet'], { cwd: root });
    await execFile('git', ['add', 'README.md'], { cwd: root });
    await execFile('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '--quiet', '-m', 'initial'], { cwd: root });
    await writeFile(join(root, 'README.md'), '# After\n');

    const result = await runReadOnlyWorker({ workerID: 'worker-4', type: 'review', projectPath: root });

    expect(result.state).toBe('completed');
    expect(result.evidence).toContainEqual({ path: 'README.md', kind: 'diff' });
    expect(await readFile(join(root, 'README.md'), 'utf8')).toBe('# After\n');
  });
});
