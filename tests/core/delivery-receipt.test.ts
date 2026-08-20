import { describe, expect, test } from 'vitest';
import { buildDeliveryReceipt, canonicalize, computeLogHash, verifyDeliveryReceipt, type ReceiptEvent } from '../../src/core/delivery-receipt';
import { evaluateDeliveryGate } from '../../src/core/delivery-gate';

function fixtureEvents(): ReceiptEvent[] {
  return [
    { sequence: 1, type: 'turn_started', payload: { prompt: '修复并验证', projectPath: '/tmp/demo' } },
    { sequence: 2, type: 'terminal_completed', payload: { sequence: 1, command: 'npm test', stdout: 'ok', stderr: '', exitCode: 0 } },
    { sequence: 3, type: 'verification_passed', payload: { kind: 'terminal', command: 'npm test' } },
    { sequence: 4, type: 'turn_ended', payload: { status: 'completed' } },
    { sequence: 5, type: 'delivery_evaluated', payload: { state: 'delivered', reasons: [] } }
  ];
}

function buildFixtureReceipt(events: ReceiptEvent[] = fixtureEvents()) {
  return buildDeliveryReceipt({
    sessionID: 's-receipt',
    events,
    gate: evaluateDeliveryGate(events),
    projectPath: '/tmp/demo',
    headCommit: 'abc123',
    branch: 'main',
    receiptID: 'r-1',
    issuedAt: '2026-08-20T12:00:00.000Z'
  });
}

describe('交付回执（哈希链 + 门禁重算）', () => {
  test('canonicalize 与键序无关', () => {
    expect(canonicalize({ b: 1, a: { d: [3, 2], c: 'x' } })).toBe(canonicalize({ a: { c: 'x', d: [3, 2] }, b: 1 }));
  });

  test('签发-校验闭环：结构与逐项检查全部通过', () => {
    const receipt = buildFixtureReceipt();
    expect(receipt.gate.state).toBe('delivered');
    expect(receipt.evidence.length).toBeGreaterThanOrEqual(2);
    const result = verifyDeliveryReceipt({ receipt, events: fixtureEvents(), evaluateGate: evaluateDeliveryGate });
    expect(result.ok).toBe(true);
    expect(result.checks.map((check) => check.name)).toEqual(['logHash', 'gate', 'evidence', 'structure']);
  });

  test('篡改任一事件字段都会破坏日志哈希', () => {
    const receipt = buildFixtureReceipt();
    const tampered = fixtureEvents().map((event) => event.sequence === 2 ? { ...event, payload: { ...event.payload, exitCode: 1 } } : event);
    const result = verifyDeliveryReceipt({ receipt, events: tampered, evaluateGate: evaluateDeliveryGate });
    expect(result.ok).toBe(false);
    expect(result.checks.find((check) => check.name === 'logHash')?.ok).toBe(false);
  });

  test('门禁重算与回执声称不一致会被发现', () => {
    const receipt = buildFixtureReceipt();
    const forged = { ...receipt, gate: { state: 'needsRepair', reasons: ['伪造'] } };
    const result = verifyDeliveryReceipt({ receipt: forged, events: fixtureEvents(), evaluateGate: evaluateDeliveryGate });
    expect(result.ok).toBe(false);
    expect(result.checks.find((check) => check.name === 'gate')?.ok).toBe(false);
  });

  test('回执区间之后的事件不影响校验（签发后的日志追加是合法的）', () => {
    const events = fixtureEvents();
    const receipt = buildFixtureReceipt(events);
    const appended = [...events, { sequence: 6, type: 'receipt_issued', payload: { receiptID: 'r-1' } }, { sequence: 7, type: 'turn_started', payload: { prompt: '新一轮' } }];
    const result = verifyDeliveryReceipt({ receipt, events: appended, evaluateGate: evaluateDeliveryGate });
    expect(result.ok).toBe(true);
  });

  test('logHash 覆盖区间截断正确', () => {
    const events = fixtureEvents();
    const receipt = buildFixtureReceipt(events);
    expect(receipt.events.fromSequence).toBe(1);
    expect(receipt.events.toSequence).toBe(5);
    expect(computeLogHash(events.slice(0, 3))).not.toBe(receipt.events.logHash);
  });
});
