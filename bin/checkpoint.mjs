/**
 * CLI 检查点：每个 session.run 前对工作区文件做哈希快照（git 跟踪文件 + 事件日志提到过的文件）。
 * undo 只恢复 Agent 改过的文件，且仅当用户没有在其后修改同一文件时执行。
 */
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { join, resolve as resolvePath } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

function hash(content) {
  return createHash('sha256').update(content).digest('hex');
}

async function gitTrackedFiles(projectPath) {
  try {
    const { stdout } = await execFileAsync('git', ['ls-files', '-z'], { cwd: projectPath, maxBuffer: 20_000_000 });
    return stdout.split('\0').filter(Boolean);
  } catch {
    return [];
  }
}

async function hashFile(projectPath, relativePath) {
  try {
    const content = await readFile(join(projectPath, relativePath), 'utf8');
    return { path: relativePath, hash: hash(content), existed: true, content };
  } catch {
    return { path: relativePath, hash: null, existed: false, content: undefined };
  }
}

export async function createCheckpoint({ checkpointRoot, projectPath, sessionID, label, extraPaths = [] }) {
  const tracked = await gitTrackedFiles(projectPath);
  const paths = [...new Set([...tracked, ...extraPaths])].slice(0, 5000);
  const entries = await Promise.all(paths.map((p) => hashFile(projectPath, p)));
  let head = '';
  try { head = (await execFileAsync('git', ['rev-parse', 'HEAD'], { cwd: projectPath })).stdout.trim(); } catch { head = ''; }
  const checkpoint = {
    id: randomUUID(),
    label,
    createdAt: new Date().toISOString(),
    sessionID,
    projectPath,
    head,
    entries: Object.fromEntries(entries.map((e) => [e.path, { hash: e.hash, existed: e.existed, content: e.content }]))
  };
  const dir = join(checkpointRoot, 'checkpoints');
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, `${checkpoint.id}.json`), JSON.stringify(checkpoint), 'utf8');
  return checkpoint.id;
}

export async function listCheckpoints(checkpointRoot) {
  const dir = join(checkpointRoot, 'checkpoints');
  let names = [];
  try { names = await readdir(dir); } catch { return []; }
  const items = await Promise.all(names.filter((n) => n.endsWith('.json')).map(async (name) => {
    try {
      const cp = JSON.parse(await readFile(join(dir, name), 'utf8'));
      return { id: cp.id, label: cp.label, createdAt: cp.createdAt, projectPath: cp.projectPath, fileCount: Object.keys(cp.entries ?? {}).length };
    } catch { return undefined; }
  }));
  return items.filter(Boolean).sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}

/** 与快照对比：返回自快照以来被修改/删除/新增的路径集合。 */
export async function diffAgainstCheckpoint(checkpoint) {
  const changed = [];
  for (const [path, entry] of Object.entries(checkpoint.entries)) {
    const current = await hashFile(checkpoint.projectPath, path);
    if (current.hash !== entry.hash) changed.push(path);
  }
  return changed;
}

/**
 * 安全撤销：undoSet 是 Agent 在检查点之后改过的文件集合。
 * 对每个文件：若当前哈希 ≠ 快照哈希 且 当前哈希 ≠ agentAfter 中记录的值，说明用户动过，拒绝覆盖。
 */
export async function undoCheckpoint({ checkpoint, agentAfter }) {
  const conflicts = [];
  const restored = [];
  for (const [path, afterHash] of Object.entries(agentAfter)) {
    const before = checkpoint.entries[path];
    if (!before) continue;
    const current = await hashFile(checkpoint.projectPath, path);
    if (current.hash === before.hash) continue; // 已回到快照状态
    if (afterHash && current.hash !== afterHash) { conflicts.push(path); continue; }
    if (before.existed && before.content !== undefined) {
      await writeFile(resolvePath(checkpoint.projectPath, path), before.content, 'utf8');
    }
    restored.push(path);
  }
  return { restored, conflicts };
}
