import { describe, expect, test } from 'vitest';
import { createSessionState, reduceSessionEvents } from '../../src/core/session-reducer';

describe('session event reducer', () => {
  test('reconstructs plan, approval state, and usage from an event stream', () => {
    const initial = createSessionState('s1');
    const state = reduceSessionEvents(initial, [
      { type: 'session_status_changed', status: 'planning' },
      { type: 'plan_updated', steps: [{ id: '1', title: 'Inspect repository', status: 'active' }] },
      { type: 'approval_requested', approvalId: 'a1', tool: 'run_command', risk: 'L2' },
      { type: 'usage_recorded', inputTokens: 100, cachedInputTokens: 20, outputTokens: 50, estimatedCost: 0.001 }
    ]);

    expect(state.status).toBe('waiting_approval');
    expect(state.plan[0]?.title).toBe('Inspect repository');
    expect(state.pendingApproval?.id).toBe('a1');
    expect(state.usage).toEqual({ inputTokens: 100, cachedInputTokens: 20, outputTokens: 50, estimatedCost: 0.001 });
  });

  test('returns to running after an approval decision', () => {
    const state = reduceSessionEvents(createSessionState('s1'), [
      { type: 'approval_requested', approvalId: 'a1', tool: 'apply_patch', risk: 'L1' },
      { type: 'approval_resolved', approvalId: 'a1', decision: 'allow' }
    ]);

    expect(state.status).toBe('running');
    expect(state.pendingApproval).toBeUndefined();
  });
});
