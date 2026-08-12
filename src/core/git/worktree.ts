import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface WorktreeRequest {
  repository: string;
  storage: string;
  taskTitle: string;
  baseRef: string;
}

function taskSlug(taskTitle: string): string {
  return taskTitle
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
}

export function createTaskBranchName(taskTitle: string): string {
  const slug = taskSlug(taskTitle);
  return slug ? `deepseek/${slug}` : `deepseek/task-${randomBytes(4).toString('hex')}`;
}

async function git(repository: string, args: string[]): Promise<string> {
  const result = await execFileAsync('git', args, { cwd: repository });
  return result.stdout.trim();
}

async function branchExists(repository: string, branch: string): Promise<boolean> {
  try {
    await git(repository, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]);
    return true;
  } catch {
    return false;
  }
}

export class GitWorktreeService {
  async create(request: WorktreeRequest): Promise<{ path: string; branch: string }> {
    const repository = resolve(request.repository);
    const storage = resolve(request.storage);
    await mkdir(storage, { recursive: true });

    const proposedBranch = createTaskBranchName(request.taskTitle);
    const branch = (await branchExists(repository, proposedBranch))
      ? `${proposedBranch}-${randomBytes(3).toString('hex')}`
      : proposedBranch;
    const directoryName = branch.replace('/', '--');
    const path = join(storage, directoryName);

    await git(repository, ['worktree', 'add', '-b', branch, path, request.baseRef]);
    return { path, branch };
  }
}
