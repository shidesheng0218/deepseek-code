import { describe, expect, test } from 'vitest';
import { CIRepairQueue } from '../../src/core/ci-repair-queue';
import { createCIRepairSession } from '../../src/core/ci-repair-session';

const repair = createCIRepairSession({
  parentSessionID: 'parent',
  projectPath: '/workspace/app',
  commit: 'abc123',
  runID: 9,
  failure: { kind: 'test', summary: '测试断言或测试套件失败。' },
  log: 'FAIL src/login.test.ts'
});

describe('CI repair queue', () => {
  test('deduplicates a repair by its deterministic child session and releases it only for its parent', () => {
    const queue = new CIRepairQueue<{ model: string }>();

    expect(queue.schedule(repair, { model: 'deepseek-chat' })).toBe(true);
    expect(queue.schedule(repair, { model: 'deepseek-chat' })).toBe(false);
    expect(queue.take('other-parent')).toEqual([]);
    expect(queue.take('parent')).toEqual([{ repair, value: { model: 'deepseek-chat' } }]);
    expect(queue.take('parent')).toEqual([]);
  });
});
