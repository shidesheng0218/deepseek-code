import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, realpath, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve } from 'node:path';

export interface WorkspaceChange {
  path: string;
  content: string;
  expectedHash?: string;
}

interface CheckpointEntry {
  path: string;
  existed: boolean;
  content?: string;
}

interface Checkpoint {
  id: string;
  label: string;
  entries: CheckpointEntry[];
}

function hash(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}

async function safePath(root: string, path: string): Promise<string> {
  const candidate = resolve(root, path);
  const fromRoot = relative(root, candidate);
  if (fromRoot === '' || fromRoot.startsWith('..') || isAbsolute(fromRoot)) throw new Error('Path is outside the workspace');
  try {
    const canonical = await realpath(candidate);
    const canonicalRelative = relative(root, canonical);
    if (canonicalRelative.startsWith('..') || isAbsolute(canonicalRelative)) throw new Error('Path is outside the workspace');
    return canonical;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return candidate;
    throw error;
  }
}

export class WorkspacePatchService {
  constructor(private readonly options: { checkpointRoot: string }) {}

  async apply(root: string, changes: WorkspaceChange[], label: string): Promise<{ checkpointId: string; changedFiles: string[] }> {
    const canonicalRoot = await realpath(root);
    const prepared = await Promise.all(changes.map(async (change) => {
      const absolutePath = await safePath(canonicalRoot, change.path);
      let before: string | undefined;
      try {
        before = await readFile(absolutePath, 'utf8');
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      }
      if (change.expectedHash && hash(before ?? '') !== change.expectedHash) throw new Error(`hash mismatch for ${change.path}`);
      return { change, absolutePath, before };
    }));

    const checkpointId = randomUUID();
    const checkpoint: Checkpoint = {
      id: checkpointId,
      label,
      entries: prepared.map(({ change, before }) => ({ path: change.path, existed: before !== undefined, ...(before === undefined ? {} : { content: before }) }))
    };
    await mkdir(this.options.checkpointRoot, { recursive: true });
    await writeFile(resolve(this.options.checkpointRoot, `${checkpointId}.json`), JSON.stringify(checkpoint), 'utf8');

    const tempPaths: Array<{ temporary: string; absolutePath: string }> = [];
    try {
      for (const { change, absolutePath } of prepared) {
        await mkdir(dirname(absolutePath), { recursive: true });
        const temporary = `${absolutePath}.deepseek-${checkpointId}.tmp`;
        await writeFile(temporary, change.content, 'utf8');
        tempPaths.push({ temporary, absolutePath });
      }
      for (const entry of tempPaths) await rename(entry.temporary, entry.absolutePath);
    } catch (error) {
      await Promise.all(tempPaths.map(async (entry) => unlink(entry.temporary).catch(() => undefined)));
      throw error;
    }

    return { checkpointId, changedFiles: prepared.map(({ change }) => change.path) };
  }

  async restore(root: string, checkpointId: string): Promise<void> {
    const checkpointPath = resolve(this.options.checkpointRoot, `${checkpointId}.json`);
    const checkpoint = JSON.parse(await readFile(checkpointPath, 'utf8')) as Checkpoint;
    const canonicalRoot = await realpath(root);
    for (const entry of checkpoint.entries) {
      const absolutePath = await safePath(canonicalRoot, entry.path);
      if (entry.existed) {
        await mkdir(dirname(absolutePath), { recursive: true });
        await writeFile(absolutePath, entry.content ?? '', 'utf8');
      } else {
        await unlink(absolutePath).catch((error: NodeJS.ErrnoException) => {
          if (error.code !== 'ENOENT') throw error;
        });
      }
    }
  }
}
