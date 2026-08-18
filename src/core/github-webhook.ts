import { createHmac, timingSafeEqual } from 'node:crypto';

export interface GitHubWorkflowRunWebhook {
  runID: number;
  commit: string;
  status: string;
  conclusion: string | null;
  url?: string;
}

export function verifyGitHubWebhookSignature(payload: string | Uint8Array, signature: string, secret: string): boolean {
  if (!secret || !signature.startsWith('sha256=')) return false;
  const expected = Buffer.from(createHmac('sha256', secret).update(payload).digest('hex'), 'utf8');
  const supplied = Buffer.from(signature.slice('sha256='.length), 'utf8');
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function parseGitHubWorkflowRunWebhook(value: unknown): GitHubWorkflowRunWebhook | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  if (root.action !== 'completed' || !root.workflow_run || typeof root.workflow_run !== 'object' || Array.isArray(root.workflow_run)) return undefined;
  const run = root.workflow_run as Record<string, unknown>;
  if (typeof run.id !== 'number' || !Number.isInteger(run.id) || typeof run.head_sha !== 'string' || !run.head_sha || typeof run.status !== 'string' || run.status !== 'completed') return undefined;
  if (!(run.conclusion === null || typeof run.conclusion === 'string')) return undefined;
  return { runID: run.id, commit: run.head_sha, status: run.status, conclusion: run.conclusion, ...(typeof run.html_url === 'string' ? { url: run.html_url } : {}) };
}
