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
});
