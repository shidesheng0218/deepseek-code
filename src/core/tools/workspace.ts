import { createHash } from 'node:crypto';
import { readFile, realpath } from 'node:fs/promises';
import { isAbsolute, relative, resolve } from 'node:path';

export async function resolveWorkspacePath(root: string, relativePath: string): Promise<string> {
  const canonicalRoot = await realpath(root);
  const candidate = resolve(canonicalRoot, relativePath);
  const fromRoot = relative(canonicalRoot, candidate);
  if (fromRoot === '' || fromRoot.startsWith('..') || isAbsolute(fromRoot)) {
    throw new Error('Path is outside the workspace');
  }

  const canonicalCandidate = await realpath(candidate);
  const canonicalRelative = relative(canonicalRoot, canonicalCandidate);
  if (canonicalRelative.startsWith('..') || isAbsolute(canonicalRelative)) {
    throw new Error('Path is outside the workspace');
  }
  return canonicalCandidate;
}

export async function readWorkspaceFile(root: string, relativePath: string, range: { startLine: number; maxLines: number }): Promise<{ content: string; sha256: string; truncated: boolean }> {
  const path = await resolveWorkspacePath(root, relativePath);
  const fullContent = await readFile(path, 'utf8');
  const lines = fullContent.endsWith('\n') ? fullContent.slice(0, -1).split('\n') : fullContent.split('\n');
  const startIndex = Math.max(0, range.startLine - 1);
  const selected = lines.slice(startIndex, startIndex + range.maxLines);
  return {
    content: selected.map((line, index) => `${startIndex + index + 1}: ${line}`).join('\n'),
    sha256: createHash('sha256').update(fullContent).digest('hex'),
    truncated: startIndex + selected.length < lines.length
  };
}
