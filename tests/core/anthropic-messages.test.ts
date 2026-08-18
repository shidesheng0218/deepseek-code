import { describe, expect, test } from 'vitest';
import { AnthropicMessagesClient, buildAnthropicMessagesRequest, parseAnthropicMessagesSse } from '../../src/core/providers/anthropic-messages';

describe('Anthropic Messages provider', () => {
  test('lowers system, tool schema and tool result messages into the Messages API contract', () => {
    const request = buildAnthropicMessagesRequest({
      model: 'claude-sonnet',
      feature: 'main_agent',
      messages: [
        { role: 'system', content: 'Use tools carefully.' },
        { role: 'user', content: 'Read README.' },
        { role: 'tool', toolCallId: 'toolu_1', content: '{"ok":true}' }
      ],
      tools: [{ type: 'function', function: { name: 'read_file', description: 'Read a file', parameters: { type: 'object' } } }]
    });

    expect(request.system).toBe('Use tools carefully.');
    expect(request.messages).toEqual([
      { role: 'user', content: 'Read README.' },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: '{"ok":true}' }] }
    ]);
    expect(request.tools).toEqual([{ name: 'read_file', description: 'Read a file', input_schema: { type: 'object' } }]);
  });

  test('parses streaming text, tool input deltas and token usage', async () => {
    const source = [
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":4}}}\n\n',
      'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"README.md\\"}"}}\n\n',
      'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n',
      'event: message_stop\ndata: {"type":"message_stop"}\n\n'
    ];
    const events = [];
    for await (const event of parseAnthropicMessagesSse(source)) events.push(event);

    expect(events).toContainEqual({ type: 'tool_call', id: 'toolu_1', name: 'read_file', arguments: { path: 'README.md' } });
    expect(events).toContainEqual({ type: 'usage', inputTokens: 12, cachedInputTokens: 4, outputTokens: 7 });
    expect(events.at(-1)).toEqual({ type: 'done' });
  });

  test('uses the Anthropic endpoint and headers without serializing the API key into the body', async () => {
    let url = '';
    let headers: Headers | undefined;
    let body = '';
    const client = new AnthropicMessagesClient({
      baseUrl: 'https://api.anthropic.example/', apiKey: 'secret-key', fetchImpl: async (input, init) => {
        url = String(input); headers = new Headers(init?.headers); body = String(init?.body);
        return new Response('event: message_stop\ndata: {"type":"message_stop"}\n\n', { status: 200 });
      }
    });
    for await (const event of client.stream({ model: 'claude-sonnet', feature: 'main_agent', messages: [{ role: 'user', content: 'Hi' }], tools: [] })) void event;

    expect(url).toBe('https://api.anthropic.example/v1/messages');
    expect(headers?.get('x-api-key')).toBe('secret-key');
    expect(headers?.get('anthropic-version')).toBeTruthy();
    expect(body).not.toContain('secret-key');
  });
});
