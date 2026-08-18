import { readFile, realpath } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';

const instructionNames = ['AGENTS.md', 'CLAUDE.md', '.deepseek.md'];
const maxInstructionBytes = 32_000;

export async function loadProjectInstructions(workspacePath: string, projectRoot = workspacePath): Promise<string> {
  const root = await realpath(projectRoot);
  const workspace = await realpath(workspacePath);
  const outside = relative(root, workspace);
  if (outside.startsWith('..')) throw new Error('Workspace is outside project root');
  const directories: string[] = [];
  for (let current = workspace; ; current = dirname(current)) {
    directories.unshift(current);
    if (current === root) break;
  }
  const rules: string[] = [];
  let remaining = maxInstructionBytes;
  for (const directory of directories) {
    for (const name of instructionNames) {
      if (remaining <= 0) break;
      try {
        const content = (await readFile(resolve(directory, name), 'utf8')).trim();
        if (!content) continue;
        const bounded = content.slice(0, remaining);
        rules.push(`## ${relative(root, resolve(directory, name)) || name}\n${bounded}`);
        remaining -= bounded.length;
      } catch { /* Missing instruction files are optional. */ }
    }
  }
  return rules.join('\n\n');
}
