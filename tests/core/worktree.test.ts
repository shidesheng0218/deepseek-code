import { execFile } from 'node:child_process';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { describe, expect, test } from 'vitest';
import { GitWorktreeService, createTaskBranchName } from '../../src/core/git/worktree';

const execFileAsync = promisify(execFile);

describe('Git worktree manager', () => {
  test('creates an isolated task branch and worktree from a repository baseline', async () => {
    const repository = await mkdtemp(join(tmpdir(), 'deepseek-repo-'));
    const storage = await mkdtemp(join(tmpdir(), 'deepseek-worktrees-'));
    await execFileAsync('git', ['init', '-b', 'main'], { cwd: repository });
    await execFileAsync('git', ['config', 'user.email', 'agent@example.com'], { cwd: repository });
    await execFileAsync('git', ['config', 'user.name', 'DeepSeek Code'], { cwd: repository });
    await writeFile(join(repository, 'README.md'), '# Example\n');
    await execFileAsync('git', ['add', 'README.md'], { cwd: repository });
    await execFileAsync('git', ['commit', '-m', 'Initial commit'], { cwd: repository });

    const service = new GitWorktreeService();
    const worktree = await service.create({ repository, storage, taskTitle: 'Fix login state sync', baseRef: 'HEAD' });
    const branch = (await execFileAsync('git', ['branch', '--show-current'], { cwd: worktree.path })).stdout.trim();

    expect(worktree.branch).toBe('deepseek/fix-login-state-sync');
    expect(branch).toBe(worktree.branch);
    expect(worktree.path.startsWith(storage)).toBe(true);
  });

  test('creates stable, shell-safe task branch names', () => {
    expect(createTaskBranchName('  Fix login state sync!  ')).toBe('deepseek/fix-login-state-sync');
    expect(createTaskBranchName('')).toMatch(/^deepseek\/task-[a-z0-9]{8}$/);
  });
});
