import { createHmac } from 'node:crypto';
import { describe, expect, test } from 'vitest';
import { parseGitHubWorkflowRunWebhook, verifyGitHubWebhookSignature } from '../../src/core/github-webhook';

describe('GitHub webhook verification', () => {
  test('accepts only an exact HMAC SHA-256 signature', () => {
    const payload = JSON.stringify({ action: 'completed', workflow_run: { id: 42, head_sha: 'abc123', status: 'completed', conclusion: 'failure' } });
    const signature = `sha256=${createHmac('sha256', 'secret').update(payload).digest('hex')}`;
    expect(verifyGitHubWebhookSignature(payload, signature, 'secret')).toBe(true);
    expect(verifyGitHubWebhookSignature(payload, `${signature.slice(0, -1)}0`, 'secret')).toBe(false);
    expect(verifyGitHubWebhookSignature(payload, signature, 'wrong')).toBe(false);
  });

  test('extracts only completed workflow events with their commit SHA', () => {
    expect(parseGitHubWorkflowRunWebhook({ action: 'completed', workflow_run: { id: 42, head_sha: 'abc123', status: 'completed', conclusion: 'failure', html_url: 'https://github.com/o/r/actions/runs/42' } })).toEqual({ runID: 42, commit: 'abc123', status: 'completed', conclusion: 'failure', url: 'https://github.com/o/r/actions/runs/42' });
    expect(parseGitHubWorkflowRunWebhook({ action: 'requested', workflow_run: { id: 42, head_sha: 'abc123', status: 'queued', conclusion: null } })).toBeUndefined();
  });
});
