import { describe, expect, test } from 'vitest';
import { evaluateDeliveryGate } from '../../src/core/delivery-gate';

describe('delivery gate', () => {
  test('rejects failed verification and unresolved approvals', () => {
    expect(evaluateDeliveryGate([{ type: 'terminal_completed', payload: { exitCode: 1 } }]).state).toBe('needsRepair');
    expect(evaluateDeliveryGate([{ type: 'approval_pending', payload: { approvalID: 'a1' } }]).state).toBe('needsAttention');
  });

  test('requires explicit successful verification before delivery', () => {
    expect(evaluateDeliveryGate([{ type: 'terminal_completed', payload: { exitCode: 0 } }]).state).toBe('handoffReady');
    expect(evaluateDeliveryGate([{ type: 'verification_passed', payload: { kind: 'test' } }]).state).toBe('delivered');
  });

  test('does not deliver while the latest GitHub Actions evidence is a failure', () => {
    expect(evaluateDeliveryGate([
      { type: 'verification_passed', payload: { kind: 'terminal' } },
      { type: 'ci_failure_classified', payload: { runID: 42, kind: 'type' } }
    ]).state).toBe('needsRepair');

    expect(evaluateDeliveryGate([
      { type: 'ci_failure_classified', payload: { runID: 42, kind: 'type' } },
      { type: 'ci_status', payload: { passed: true } },
      { type: 'verification_passed', payload: { kind: 'github_ci' } }
    ]).state).toBe('delivered');
  });

  test('rejects failed tool completions emitted by the executor', () => {
    expect(evaluateDeliveryGate([{ type: 'tool_completed', payload: { ok: false, error: 'fixture failure' } }]).state).toBe('needsRepair');
  });

  test('treats a tool that started without a terminal event as an unknown side effect', () => {
    expect(evaluateDeliveryGate([{ type: 'tool_started', payload: { id: 'tool-1' } }]).state).toBe('needsAttention');
    expect(evaluateDeliveryGate([
      { type: 'tool_started', payload: { id: 'tool-1' } },
      { type: 'tool_completed', payload: { id: 'tool-1', ok: true } },
      { type: 'verification_passed', payload: { kind: 'test' } }
    ]).state).toBe('delivered');
  });

  test('does not mark CI repair delivered until the original PR update is acknowledged', () => {
    expect(evaluateDeliveryGate([
      { type: 'verification_passed', payload: { kind: 'github_ci' } },
      { type: 'ci_repair_pr_update_ready', payload: { number: 7 } }
    ]).state).toBe('needsAttention');
    expect(evaluateDeliveryGate([
      { type: 'verification_passed', payload: { kind: 'github_ci' } },
      { type: 'ci_repair_pr_update_ready', payload: { number: 7 } },
      { type: 'github_pr_updated', payload: { number: 7 } }
    ]).state).toBe('delivered');
  });
});
