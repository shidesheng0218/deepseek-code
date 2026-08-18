import { describe, expect, test } from 'vitest';
import { createCIRepairSession } from '../../src/core/ci-repair-session';

describe('CI repair sessions', () => {
  test('creates a deterministic child session with the parent CI evidence', () => {
    const input = {
      parentSessionID: 'session-parent',
      projectPath: '/workspace/app',
      commit: 'a1b2c3d4',
      runID: 42,
      failure: { kind: 'type' as const, summary: '类型检查或编译接口不匹配。' },
      log: 'src/login.ts(14,3): error TS2322: Type number is not assignable to string'
    };

    const repair = createCIRepairSession(input);

    expect(repair.sessionID).toMatch(/^ci-repair-[a-f0-9]{24}$/);
    expect(repair.parentSessionID).toBe('session-parent');
    expect(repair.commit).toBe('a1b2c3d4');
    expect(repair.runID).toBe(42);
    expect(repair.failureKind).toBe('type');
    expect(repair.logHash).toMatch(/^[a-f0-9]{64}$/);
    expect(repair.prompt).toContain('GitHub Actions Run #42');
    expect(repair.prompt).toContain('TS2322');
    expect(createCIRepairSession(input).sessionID).toBe(repair.sessionID);
  });
});
