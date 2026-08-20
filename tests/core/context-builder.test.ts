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

  test('drops orphan tool messages whose assistant tool_calls were trimmed away', () => {
    const messages: AgentMessage[] = [
      { role: 'system', content: '规则' },
      { role: 'assistant', content: '', toolCalls: [{ id: 'old-call', name: 'read_file', arguments: {} }] },
      { role: 'tool', content: '旧结果', toolCallId: 'old-call' },
      { role: 'user', content: '中间问题一' },
      { role: 'user', content: '中间问题二' },
      { role: 'assistant', content: '', toolCalls: [{ id: 'new-call', name: 'read_file', arguments: { path: 'a' } }] },
      { role: 'tool', content: '新结果', toolCallId: 'new-call' }
    ];
    // keepRecent=5 的窗口恰好从孤儿 tool 消息开始（其 assistant tool_calls 在窗口外）
    const built = buildContext(messages, { ...DEFAULT_CONTEXT_BUDGET, keepRecent: 5 });
    expect(built.some((message) => message.toolCallId === 'old-call')).toBe(false);
    expect(built.some((message) => message.toolCallId === 'new-call')).toBe(true);
    expect(built.some((message) => message.role === 'assistant' && message.toolCalls?.some((call) => call.id === 'new-call'))).toBe(true);
  });

  test('keeps paired tool_calls and results within the budget window intact', () => {
    const messages: AgentMessage[] = [
      { role: 'system', content: '规则' },
      { role: 'user', content: '读取文件' },
      { role: 'assistant', content: '先读。', toolCalls: [{ id: 'call-1', name: 'read_file', arguments: { path: 'a.ts' } }] },
      { role: 'tool', content: '文件内容', toolCallId: 'call-1' },
      { role: 'assistant', content: '读完了。' }
    ];
    const built = buildContext(messages);
    expect(built).toContainEqual({ role: 'assistant', content: '先读。', toolCalls: [{ id: 'call-1', name: 'read_file', arguments: { path: 'a.ts' } }] });
    expect(built).toContainEqual({ role: 'tool', content: '文件内容', toolCallId: 'call-1' });
  });
});
