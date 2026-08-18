import { describe, expect, test } from 'vitest';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PersistentTerminal } from '../../src/core/persistent-terminal';

describe('persistent terminal', () => {
  test('keeps shell state and provides monotonic transcript sequences', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'deepseek-terminal-'));
    const terminal = new PersistentTerminal({ cwd: directory, shell: '/bin/sh' });
    try {
      const first = await terminal.exec('export DEEPSEEK_PERSISTED=value; pwd');
      const second = await terminal.exec('printf "$DEEPSEEK_PERSISTED"');

      expect(first.stdout).toContain(directory);
      expect(second.stdout).toBe('value');
      expect(second.sequence).toBeGreaterThan(first.sequence);
      expect(terminal.read(0).map((entry) => entry.sequence)).toEqual(expect.arrayContaining([first.sequence, second.sequence]));
    } finally {
      await terminal.close();
    }
  });
});
