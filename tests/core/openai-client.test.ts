import { describe, expect, test } from 'vitest';
import { OpenAICompatibleClient } from '../../src/core/providers/openai-compatible';

describe('OpenAI-compatible HTTP client', () => {
  test('posts a streaming chat request with the API key isolated to the Authorization header', async () => {
    let receivedUrl = '';
    let receivedAuthorization = '';
    let receivedBody: Record<string, unknown> | undefined;
    const client = new OpenAICompatibleClient({
      baseUrl: 'https://api.example.test/v1/',
      apiKey: 'secret-key',
      fetchImpl: async (url, init) => {
        receivedUrl = String(url);
        receivedAuthorization = new Headers(init?.headers).get('Authorization') ?? '';
        receivedBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response('data: {"choices":[{"delta":{"content":"Ready"}}]}\n\ndata: [DONE]\n\n', { status: 200 });
      }
    });

    const events = [];
    for await (const event of client.stream({ model: 'deepseek-chat', messages: [{ role: 'user', content: 'Plan the task' }], feature: 'plan', tools: [] })) {
      events.push(event);
    }

    expect(receivedUrl).toBe('https://api.example.test/v1/chat/completions');
    expect(receivedAuthorization).toBe('Bearer secret-key');
    expect(receivedBody).toMatchObject({ model: 'deepseek-chat', stream: true, max_tokens: 4096 });
    expect(events).toContainEqual({ type: 'text_delta', text: 'Ready' });
  });

  test('preserves a tool call id when feeding a tool result back to the model', async () => {
    let receivedBody: Record<string, unknown> | undefined;
    const client = new OpenAICompatibleClient({
      baseUrl: 'https://api.example.test/v1/',
      apiKey: 'secret-key',
      fetchImpl: async (url, init) => {
        void url;
        receivedBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response('data: [DONE]\n\n', { status: 200 });
      }
    });

    for await (const event of client.stream({
      model: 'deepseek-chat',
      messages: [{ role: 'tool', content: '{"ok":true}', toolCallId: 'call_123' }],
      feature: 'main_agent',
      tools: []
    })) { void event; }

    expect((receivedBody?.messages as Array<Record<string, unknown>>)[0]).toMatchObject({ role: 'tool', tool_call_id: 'call_123' });
  });

  test('serializes assistant tool_calls in the OpenAI wire format', async () => {
    let receivedBody: Record<string, unknown> | undefined;
    const client = new OpenAICompatibleClient({
      baseUrl: 'https://api.example.test/v1/',
      apiKey: 'secret-key',
      fetchImpl: async (url, init) => {
        void url;
        receivedBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response('data: [DONE]\n\n', { status: 200 });
      }
    });

    for await (const event of client.stream({
      model: 'kimi-k2.7-code',
      messages: [
        { role: 'user', content: '读取文件' },
        { role: 'assistant', content: '', toolCalls: [{ id: 'call_1', name: 'read_file', arguments: { path: 'README.md' } }] },
        { role: 'tool', content: '内容', toolCallId: 'call_1' }
      ],
      feature: 'main_agent',
      tools: []
    })) { void event; }

    const wire = receivedBody?.messages as Array<Record<string, unknown>>;
    expect(wire[1]).toMatchObject({
      role: 'assistant',
      tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'read_file', arguments: '{"path":"README.md"}' } }]
    });
    expect(wire[2]).toMatchObject({ role: 'tool', tool_call_id: 'call_1' });
  });

  test('passes the configured abort signal into the model request', async () => {
    const controller = new AbortController();
    let receivedSignal: AbortSignal | null | undefined;
    const client = new OpenAICompatibleClient({
      baseUrl: 'https://api.example.test/v1/', apiKey: 'secret-key', signal: controller.signal,
      fetchImpl: async (_url, init) => { receivedSignal = init?.signal; return new Response('data: [DONE]\n\n', { status: 200 }); }
    });
    for await (const _event of client.stream({ model: 'deepseek-chat', messages: [], feature: 'main_agent', tools: [] })) { void _event; }
    expect(receivedSignal).toBe(controller.signal);
  });
});
