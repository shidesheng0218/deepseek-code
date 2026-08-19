import { describe, expect, test } from 'vitest';
import { decideExecution, decisionInstructions } from '../../src/core/execution-decision';

describe('execution decision', () => {
  test('simple questions get a fast, direct contract with no tools', () => {
    const decision = decideExecution('什么是闭包？');
    expect(decision.modelTier).toBe('fast');
    expect(decision.responseContract).toBe('direct');
    expect(decision.allowWrite).toBe(false);
    expect(decisionInstructions(decision)).toContain('直接给出自然、准确的结论');
  });

  test('code changes require tests and disallow web', () => {
    const decision = decideExecution('修复登录状态不同步的问题');
    expect(decision.responseContract).toBe('change');
    expect(decision.requiredEvidence).toContain('tests');
    expect(decision.allowWeb).toBe(false);
    expect(decisionInstructions(decision)).toContain('不要联网');
  });

  test('web research requires citations and allows web', () => {
    const decision = decideExecution('查一下今天的天气');
    expect(decision.responseContract).toBe('research');
    expect(decision.requiredEvidence).toContain('citation');
    expect(decision.allowWeb).toBe(true);
  });

  test('delivery requires tests and CI', () => {
    const decision = decideExecution('修复完成后提交并创建 PR');
    expect(decision.responseContract).toBe('delivery');
    expect(decision.allowCI).toBe(true);
  });
});
