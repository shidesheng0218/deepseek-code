import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { createWorkspaceAgentTools } from '../../src/core/tools/agent-tools';

describe('workspace agent tools', () => {
  test('reads files and applies an optimistic, checkpointed patch', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-'));
    const checkpoints = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-checkpoints-'));
    await writeFile(join(root, 'app.ts'), 'export const value = 1;\n');
    const tools = createWorkspaceAgentTools({ root, checkpointRoot: checkpoints });

    const before = await tools.read_file({ path: 'app.ts', startLine: 1, maxLines: 10 });
    const result = await tools.apply_patch({
      changes: [{ path: 'app.ts', content: 'export const value = 2;\n', expectedHash: before.sha256 }],
      label: 'update value'
    });

    expect(result.changedFiles).toEqual(['app.ts']);
    expect(await readFile(join(root, 'app.ts'), 'utf8')).toContain('value = 2');
    expect(result.checkpointId).toEqual(expect.any(String));
  });

  test('reports git status from the selected workspace only', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-'));
    const checkpoints = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-checkpoints-'));
    const tools = createWorkspaceAgentTools({ root, checkpointRoot: checkpoints });

    await expect(tools.inspect_git({})).resolves.toEqual(expect.objectContaining({ ok: false }));
  });

  test('rejects directory traversal through every workspace tool', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-'));
    const checkpoints = await mkdtemp(join(tmpdir(), 'deepseek-agent-tools-checkpoints-'));
    const tools = createWorkspaceAgentTools({ root, checkpointRoot: checkpoints });

    await expect(tools.list_directory({ path: '../' })).rejects.toThrow('outside the workspace');
  });
});
