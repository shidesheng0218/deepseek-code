import { describe, expect, test } from 'vitest';
import { mkdir, mkdtemp, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadLanguageServerConfigs } from '../../src/core/lsp-config';

describe('LSP configuration', () => {
  test('loads explicitly configured language servers', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-lsp-'));
    await mkdir(join(root, '.deepseek'));
    await writeFile(join(root, '.deepseek', 'lsp.json'), JSON.stringify({ servers: [{ command: 'sourcekit-lsp', args: [], languages: ['swift'] }] }));
    await expect(loadLanguageServerConfigs(root)).resolves.toEqual([{ command: 'sourcekit-lsp', args: [], rootPath: await realpath(root), languages: ['swift'] }]);
  });
});
