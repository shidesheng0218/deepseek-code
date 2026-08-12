import { execFile as execFileCallback } from 'node:child_process';
import { readFile, readdir, realpath } from 'node:fs/promises';
import { promisify } from 'node:util';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { readWorkspaceFile } from './workspace';
import { WorkspacePatchService, type WorkspaceChange } from './workspace-patch';

const execFile = promisify(execFileCallback);

export interface WorkspaceAgentTools {
  list_directory(input: Record<string, unknown>): Promise<unknown>;
  search_workspace(input: Record<string, unknown>): Promise<unknown>;
  read_file(input: Record<string, unknown>): Promise<Awaited<ReturnType<typeof readWorkspaceFile>>>;
  apply_patch(input: Record<string, unknown>): Promise<{ checkpointId: string; changedFiles: string[] }>;
  inspect_git(input: Record<string, unknown>): Promise<unknown>;
  run_command(input: Record<string, unknown>): Promise<unknown>;
}

function stringInput(input: Record<string, unknown>, key: string, fallback = ''): string {
  const value = input[key];
  return typeof value === 'string' ? value : fallback;
}

function numberInput(input: Record<string, unknown>, key: string, fallback: number): number {
  const value = input[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

async function listFiles(root: string, directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    if (entry.name === '.git' || entry.name === 'node_modules' || entry.name === '.deepseek') continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await listFiles(root, path));
    else files.push(relative(root, path));
  }
  return files;
}

async function resolveWorkspaceDirectory(root: string, path: string): Promise<string> {
  const canonicalRoot = await realpath(root);
  const candidate = resolve(canonicalRoot, path);
  const fromRoot = relative(canonicalRoot, candidate);
  if (fromRoot.startsWith('..') || isAbsolute(fromRoot)) throw new Error('Path is outside the workspace');
  const canonicalCandidate = await realpath(candidate);
  const canonicalRelative = relative(canonicalRoot, canonicalCandidate);
  if (canonicalRelative.startsWith('..') || isAbsolute(canonicalRelative)) throw new Error('Path is outside the workspace');
  return canonicalCandidate;
}

export function createWorkspaceAgentTools(options: { root: string; checkpointRoot: string }): WorkspaceAgentTools {
  const patchService = new WorkspacePatchService({ checkpointRoot: options.checkpointRoot });
  return {
    async list_directory(input) {
      const path = stringInput(input, 'path', '.');
      const directory = await resolveWorkspaceDirectory(options.root, path);
      const entries = await readdir(directory, { withFileTypes: true });
      return entries.filter((entry) => entry.name !== '.git' && entry.name !== 'node_modules').map((entry) => ({ name: entry.name, type: entry.isDirectory() ? 'directory' : 'file' }));
    },
    async search_workspace(input) {
      const query = stringInput(input, 'query');
      if (!query) throw new Error('search_workspace requires query');
      const files = await listFiles(options.root, options.root);
      const matches: Array<{ path: string; line: number; text: string }> = [];
      for (const path of files.slice(0, 2000)) {
        try {
          const content = await readFile(join(options.root, path), 'utf8');
          content.split('\n').forEach((line, index) => {
            if (line.toLowerCase().includes(query.toLowerCase()) && matches.length < 100) matches.push({ path, line: index + 1, text: line.slice(0, 300) });
          });
        } catch {
          // Binary or unreadable files are intentionally skipped.
        }
      }
      return { matches, truncated: matches.length >= 100 };
    },
    async read_file(input) {
      return readWorkspaceFile(options.root, stringInput(input, 'path'), {
        startLine: numberInput(input, 'startLine', 1),
        maxLines: Math.min(numberInput(input, 'maxLines', 200), 500)
      });
    },
    async apply_patch(input) {
      const rawChanges = input.changes;
      if (!Array.isArray(rawChanges) || rawChanges.length === 0) throw new Error('apply_patch requires changes');
      const changes = rawChanges.map((change) => {
        if (!change || typeof change !== 'object') throw new Error('invalid patch change');
        const candidate = change as Record<string, unknown>;
        const path = stringInput(candidate, 'path');
        const content = stringInput(candidate, 'content');
        if (!path) throw new Error('patch path is required');
        return { path, content, ...(typeof candidate.expectedHash === 'string' ? { expectedHash: candidate.expectedHash } : {}) } satisfies WorkspaceChange;
      });
      return patchService.apply(options.root, changes, stringInput(input, 'label', 'Agent patch'));
    },
    async inspect_git() {
      try {
        const result = await execFile('git', ['-C', options.root, 'status', '--short', '--branch'], { maxBuffer: 200_000 });
        return { ok: true, output: result.stdout.slice(0, 20_000) };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return { ok: false, error: message.slice(0, 1_000) };
      }
    },
    async run_command(input) {
      const command = stringInput(input, 'command').trim();
      if (!command) throw new Error('run_command requires command');
      const timeout = Math.min(Math.max(numberInput(input, 'timeoutMs', 120_000), 1_000), 600_000);
      const result = await execFile('/bin/sh', ['-lc', command], { cwd: options.root, timeout, maxBuffer: 500_000 });
      return { ok: true, stdout: result.stdout.slice(0, 50_000), stderr: result.stderr.slice(0, 20_000) };
    }
  };
}
