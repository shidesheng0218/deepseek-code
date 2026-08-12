import { describe, expect, test } from 'vitest';
import { buildChatRequest, parseOpenAICompatibleSse } from '../../src/core/providers/openai-compatible';

describe('OpenAI-compatible provider adapter', () => {
  test('sets a feature-specific output cap and usage streaming', () => {
    const request = buildChatRequest({
      model: 'deepseek-chat',
      messages: [{ role: 'user', content: 'Inspect this repository' }],
      feature: 'plan',
      tools: []
    });

    expect(request.max_tokens).toBe(4096);
    expect(request.stream).toBe(true);
    expect(request.stream_options).toEqual({ include_usage: true });
  });

  test('parses text, tool calls, usage, and completion from split SSE chunks', async () => {
    const source = [
      'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\\"path\\":\\"README"}}]}}]}\n\n',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":".md\\"}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":4}}\n\n',
      'data: [DONE]\n\n'
    ];

    const events = [];
    for await (const event of parseOpenAICompatibleSse(source)) events.push(event);

    expect(events).toContainEqual({ type: 'text_delta', text: 'Hello' });
    expect(events).toContainEqual({ type: 'tool_call', id: 'call_1', name: 'read_file', arguments: { path: 'README.md' } });
    expect(events).toContainEqual({ type: 'usage', inputTokens: 10, outputTokens: 4, cachedInputTokens: 0 });
    expect(events.at(-1)).toEqual({ type: 'done' });
  });
});
