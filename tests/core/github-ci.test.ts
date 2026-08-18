import { describe, expect, test } from 'vitest';
import { getGitHubCIStatus } from '../../src/core/github-ci';

describe('GitHub CI status', () => {
  test('normalizes GitHub Actions runs and binds them to the current commit', async () => {
    const result = await getGitHubCIStatus('/fixture', 'abc123', async () => JSON.stringify([
      { databaseId: 1, displayTitle: 'CI', status: 'completed', conclusion: 'success', headSha: 'abc123', url: 'https://github.com/o/r/actions/runs/1' },
      { databaseId: 2, displayTitle: 'Old CI', status: 'completed', conclusion: 'failure', headSha: 'old', url: 'https://github.com/o/r/actions/runs/2' }
    ]));
    expect(result.currentCommit).toEqual([{ id: 1, name: 'CI', status: 'completed', conclusion: 'success', url: 'https://github.com/o/r/actions/runs/1' }]);
    expect(result.staleCount).toBe(1);
    expect(result.passed).toBe(true);
  });

  test('does not treat an incomplete or failed current Commit run as passed', async () => {
    const result = await getGitHubCIStatus('/fixture', 'abc123', async () => JSON.stringify([
      { databaseId: 1, displayTitle: 'CI', status: 'completed', conclusion: 'failure', headSha: 'abc123', url: 'https://github.com/o/r/actions/runs/1' },
      { databaseId: 2, displayTitle: 'Lint', status: 'in_progress', conclusion: null, headSha: 'abc123', url: 'https://github.com/o/r/actions/runs/2' }
    ]));
    expect(result.passed).toBe(false);
  });
});
