import { describe, expect, test } from 'vitest';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadProjectInstructions } from '../../src/core/project-instructions';

describe('project instructions', () => {
  test('merges CLAUDE and AGENTS files from root to current workspace directory', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-rules-'));
    const nested = join(root, 'packages', 'app');
    await mkdir(nested, { recursive: true });
    await writeFile(join(root, 'AGENTS.md'), 'root-agent-rule');
    await writeFile(join(root, 'CLAUDE.md'), 'root-claude-rule');
    await writeFile(join(root, 'packages', 'AGENTS.md'), 'package-agent-rule');
    await writeFile(join(nested, '.deepseek.md'), 'local-deepseek-rule');

    const instructions = await loadProjectInstructions(nested, root);

    expect(instructions).toContain('root-agent-rule');
    expect(instructions).toContain('root-claude-rule');
    expect(instructions.indexOf('root-agent-rule')).toBeLessThan(instructions.indexOf('package-agent-rule'));
    expect(instructions).toContain('local-deepseek-rule');
  });
});
