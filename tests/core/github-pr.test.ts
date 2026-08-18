import { describe, expect, test } from 'vitest';
import { buildCIRepairComment, findGitHubPullRequestForCommit, updateGitHubPullRequest } from '../../src/core/github-pr';

describe('GitHub pull request linkage', () => {
  test('finds the PR whose head SHA matches the current commit and preserves lineage', async () => {
    const result = await findGitHubPullRequestForCommit('abc123', async () => JSON.stringify([
      { number: 7, title: 'Fix login', headRefName: 'fix/login', baseRefName: 'main', headRefOid: 'abc123', url: 'https://github.com/o/r/pull/7', body: 'Original' },
      { number: 8, title: 'Stale', headRefName: 'stale', baseRefName: 'main', headRefOid: 'old', url: 'https://github.com/o/r/pull/8', body: '' }
    ]));

    expect(result).toEqual({ number: 7, title: 'Fix login', headBranch: 'fix/login', baseBranch: 'main', headSHA: 'abc123', url: 'https://github.com/o/r/pull/7', body: 'Original' });
  });

  test('builds a bounded repair comment with the original run and commit evidence', () => {
    const comment = buildCIRepairComment({ runID: 42, commit: 'abc123', summary: '类型检查失败。', repairSessionID: 'ci-repair-1', result: '已修复并完成本地验证。' });
    expect(comment).toContain('Run #42');
    expect(comment).toContain('abc123');
    expect(comment).toContain('ci-repair-1');
    expect(comment.length).toBeLessThan(20_000);
  });

  test('updates only the explicitly selected PR through gh', async () => {
    let args: string[] = [];
    await expect(updateGitHubPullRequest(7, 'Repair summary', async (value) => { args = value; return ''; })).resolves.toEqual({ number: 7, updated: true });
    expect(args).toEqual(['pr', 'comment', '7', '--body', 'Repair summary']);
  });
});
