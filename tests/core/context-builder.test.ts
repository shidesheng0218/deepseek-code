import { describe, expect, test } from 'vitest';
import { buildContext, DEFAULT_CONTEXT_BUDGET } from '../../src/core/context-builder';
import type { AgentMessage } from '../../src/core/agent-executor';

describe('context builder', () => {
  test('keeps system rules and recent messages', () => {
    const messages: AgentMessage[] = [
      { role: 'system', content: '安全规则' },
      ...Array.from({ length: 30 }, (_, index) => ({ role: 'user' as const, content: `第 ${index} 轮` }))
    ];
    const built = buildContext(messages);
    expect(built[0]).toEqual({ role: 'system', content: '安全规则' });
    expect(built.filter((message) => message.role === 'user').length).toBeLessThanOrEqual(DEFAULT_CONTEXT_BUDGET.keepRecent);
  });

  test('compresses oversized tool output with a traceable summary', () => {
    const longOutput = 'x'.repeat(20_000);
    const messages: AgentMessage[] = [
      { role: 'system', content: '规则' },
      { role: 'user', content: '读取文件' },
      { role: 'tool', content: longOutput, toolCallId: 't1' }
    ];
    const built = buildContext(messages);
    const tool = built.find((message) => message.role === 'tool');
    expect(tool!.content.length).toBeLessThan(longOutput.length);
    expect(tool!.content).toContain('已压缩');
    expect(tool!.content).toContain('Evidence');
  });

  test('respects the total character budget', () => {
    const messages: AgentMessage[] = [
      { role: 'system', content: '规则' },
      ...Array.from({ length: 25 }, (_, index) => ({ role: 'user' as const, content: `内容 ${index} ${'y'.repeat(8_000)}` }))
    ];
    const built = buildContext(messages);
    const total = built.reduce((sum, message) => sum + message.content.length, 0);
    expect(total).toBeLessThanOrEqual(DEFAULT_CONTEXT_BUDGET.maxChars + 2);
  });
});
