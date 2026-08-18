import { readdir, realpath } from 'node:fs/promises';
import { join, relative } from 'node:path';

export type WorkerType = 'explore' | 'review';

export interface WorkerContract {
  workerID: string;
  type: WorkerType;
  projectPath: string;
}

export interface WorkerEvidence {
  path: string;
  kind: 'file' | 'directory';
}

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

export async function runReadOnlyWorker(contract: WorkerContract): Promise<WorkerResultEnvelope> {
  try {
    const root = await realpath(contract.projectPath);
    const evidence: WorkerEvidence[] = [];
    await listWorkspace(root, root, evidence, 200);
    const files = evidence.filter((item) => item.kind === 'file');
    const directories = evidence.filter((item) => item.kind === 'directory');
    if (contract.type === 'review') {
      return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: `只读 Review 已索引 ${files.length} 个文件和 ${directories.length} 个目录；请由主 Agent 决定是否运行验证。`, evidence, warnings: ['Worker 未执行命令、未修改文件。'] };
    }
    return { workerID: contract.workerID, type: contract.type, state: 'completed', summary: `Explore 已找到 ${files.length} 个文件和 ${directories.length} 个目录：${files.slice(0, 12).map((item) => item.path).join(', ') || '空工作区'}`, evidence, warnings: [] };
  } catch (error) {
    return { workerID: contract.workerID, type: contract.type, state: 'failed', summary: error instanceof Error ? error.message : String(error), evidence: [], warnings: ['Worker 仅可读取工作区。'] };
  }
}
