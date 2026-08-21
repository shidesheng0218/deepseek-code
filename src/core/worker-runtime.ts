import { readFile, readdir, realpath } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';

export type WorkerType = 'explore' | 'review' | 'research' | 'ci' | 'verify';

export interface WorkerContract {
  workerID: string;
  type: WorkerType;
  projectPath: string;
  query?: string;
}

export interface WorkerEvidence {
  path: string;
  kind: 'file' | 'directory' | 'diff';
}

const execFile = promisify(execFileCallback);

export interface WorkerResultEnvelope {
  workerID: string;
  type: WorkerType;
  state: 'completed' | 'failed';
  summary: string;
  evidence: WorkerEvidence[];
  warnings: string[];
}

async function listWorkspace(root: string, directory: string, evidence: WorkerEvidence[], limit: number): Promise<void> {
  if (evidence.length >= limit) return;
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    if (evidence.length >= limit) return;
    if (entry.name === '.git' || entry.name === 'node_modules' || entry.name === '.deepseek') continue;
    const path = join(directory, entry.name);
    const relativePath = relative(root, path);
    if (entry.isDirectory()) {
      evidence.push({ path: relativePath, kind: 'directory' });
      await listWorkspace(root, path, evidence, limit);
    } else if (entry.isFile()) evidence.push({ path: relativePath, kind: 'file' });
  }
}

async function findWorkspaceMatches(root: string, evidence: WorkerEvidence[], query: string): Promise<WorkerEvidence[]> {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return evidence.filter((item) => item.kind === 'file').slice(0, 40);
  const matches: WorkerEvidence[] = [];
  for (const item of evidence) {
    if (item.kind !== 'file' || matches.length >= 40) continue;
    if (item.path.toLowerCase().includes(normalized)) { matches.push(item); continue; }
    try {
      const content = (await readFile(join(root, item.path), 'utf8')).slice(0, 200_000).toLowerCase();
      if (content.includes(normalized)) matches.push(item);
    } catch { /* Binary or inaccessible files are not evidence for a read-only text research task. */ }
  }
  return matches;
}

async function changedFiles(root: string): Promise<string[]> {
  try {
    const { stdout } = await execFile('git', ['-C', root, 'diff', '--no-ext-diff', '--unified=0'], { maxBuffer: 200_000 });
    return [...new Set(stdout.split('\n').flatMap((line) => line.startsWith('+++ b/') ? [line.slice(6)] : []))].slice(0, 80);
  } catch { return []; }
}

function isCIConfiguration(path: string): boolean {
  return path.startsWith('.github/workflows/') || /(^|\/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.toml|Package\.swift|Gemfile|requirements\.txt)$/i.test(path);
}

export async function runReadOnlyWorker(contract: WorkerContract): Promise<WorkerResultEnvelope> {
  try {
    const root = await realpath(contract.projectPath);
    const evidence: WorkerEvidence[] = [];
    await listWorkspace(root, root, evidence, 200);
    const files = evidence.filter((item) => item.kind === 'file');
    const directories = evidence.filter((item) => item.kind === 'directory');
    if (contract.type === 'review') {
      const changed = await changedFiles(root);
      const diffEvidence = changed.map((path) => ({ path, kind: 'diff' as const }));
      return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: changed.length ? `只读 Review 找到 ${changed.length} 个当前 Diff 文件：${changed.slice(0, 12).join(', ')}` : `只读 Review 未发现当前 Git Diff；已索引 ${files.length} 个文件和 ${directories.length} 个目录。`, evidence: changed.length ? diffEvidence : evidence, warnings: ['Worker 未修改文件、未运行写入命令。'] };
    }
    if (contract.type === 'research') {
      const query = contract.query?.trim() ?? '';
      const matches = await findWorkspaceMatches(root, evidence, query);
      return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: `Research 在工作区中为”${query || '项目文档'}”找到 ${matches.length} 条只读证据：${matches.slice(0, 12).map((item) => item.path).join(', ') || '无匹配文件'}`, evidence: matches, warnings: ['Worker 未联网、未修改文件；外部研究由主 Session 的 Web 工具执行。'] };
    }
    if (contract.type === 'ci') {
      const ciEvidence = files.filter((item) => isCIConfiguration(item.path));
      return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: `CI Worker 找到 ${ciEvidence.length} 个工作流或构建配置文件：${ciEvidence.slice(0, 12).map((item) => item.path).join(', ') || '无 CI 配置'}`, evidence: ciEvidence, warnings: ['Worker 未触发 CI、未修改文件；失败日志与 GitHub 状态由主 Session 工具读取。'] };
    }
    if (contract.type === 'verify') {
      // Verifier Worker 不在这里实现——它需要独立 worktree + 允许运行测试命令，
      // 与只读 Worker 的沙箱模型不兼容。Verifier 由 main.ts 的 runVerifierWorker() 直接调度。
      return { workerID: contract.workerID, type: contract.type, state: 'failed', summary: 'verify worker must be invoked through runVerifierWorker(), not the read-only worker subprocess', evidence: [], warnings: [] };
    }
    return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: `Explore 已找到 ${files.length} 个文件和 ${directories.length} 个目录：${files.slice(0, 12).map((item) => item.path).join(', ') || '空工作区'}`, evidence, warnings: [] };
  } catch (error) {
    return { workerID: contract.workerID, type: contract.type, state: 'failed', summary: error instanceof Error ? error.message : String(error), evidence: [], warnings: ['Worker 仅可读取工作区。'] };
  }
}
