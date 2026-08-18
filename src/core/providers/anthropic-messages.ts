import type { ModelEvent } from './openai-compatible';

export interface AnthropicMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  toolCallId?: string;
}

export interface AnthropicChatRequestInput {
  model: string;
  messages: AnthropicMessage[];
  feature: 'plan' | 'main_agent' | 'explore' | 'review' | 'summary';
  tools: unknown[];
}

interface AnthropicToolResultBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
}

interface AnthropicMessageRequest {
  role: 'user' | 'assistant';
  content: string | AnthropicToolResultBlock[];
}

export interface AnthropicMessagesRequest {
  model: string;
  max_tokens: number;
  stream: true;
  system?: string;
  messages: AnthropicMessageRequest[];
  tools?: Array<{ name: string; description?: string; input_schema: Record<string, unknown> }>;
}

export interface AnthropicMessagesClientOptions {
  baseUrl: string;
  apiKey: string;
  fetchImpl?: typeof fetch;
  signal?: AbortSignal;
}

const OUTPUT_CAPS: Record<AnthropicChatRequestInput['feature'], number> = {
  plan: 4096,
  main_agent: 8192,
  explore: 2048,
  review: 4096,
  summary: 1024
};

function lowerTools(tools: unknown[]): Array<{ name: string; description?: string; input_schema: Record<string, unknown> }> {
  return tools.flatMap((candidate) => {
    if (!candidate || typeof candidate !== 'object') return [];
    const functionDefinition = (candidate as { function?: unknown }).function;
    if (!functionDefinition || typeof functionDefinition !== 'object') return [];
    const name = (functionDefinition as { name?: unknown }).name;
    const description = (functionDefinition as { description?: unknown }).description;
    const inputSchema = (functionDefinition as { parameters?: unknown }).parameters;
    if (typeof name !== 'string' || !name || !inputSchema || typeof inputSchema !== 'object' || Array.isArray(inputSchema)) return [];
    return [{ name, ...(typeof description === 'string' ? { description } : {}), input_schema: inputSchema as Record<string, unknown> }];
  });
}

export function buildAnthropicMessagesRequest(input: AnthropicChatRequestInput): AnthropicMessagesRequest {
  const system = input.messages.filter((message) => message.role === 'system').map((message) => message.content).join('\n\n');
  const messages = input.messages.flatMap((message): AnthropicMessageRequest[] => {
    if (message.role === 'system') return [];
    if (message.role === 'tool' && message.toolCallId) {
      return [{ role: 'user', content: [{ type: 'tool_result', tool_use_id: message.toolCallId, content: message.content }] }];
    }
    if (message.role === 'tool') return [{ role: 'user', content: message.content }];
    return [{ role: message.role, content: message.content }];
  });
  const tools = lowerTools(input.tools);
  return {
    model: input.model,
    max_tokens: OUTPUT_CAPS[input.feature],
    stream: true,
    ...(system ? { system } : {}),
    messages,
    ...(tools.length ? { tools } : {})
  };
}

function messagesEndpoint(baseUrl: string): URL {
  const base = new URL(baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`);
  return new URL(base.pathname.endsWith('/v1/') ? 'messages' : 'v1/messages', base);
}

export class AnthropicMessagesClient {
  private readonly endpoint: URL;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly options: AnthropicMessagesClientOptions) {
    this.endpoint = messagesEndpoint(options.baseUrl);
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async *stream(input: AnthropicChatRequestInput): AsyncGenerator<ModelEvent> {
    const response = await this.fetchImpl(this.endpoint, {
      method: 'POST',
      headers: {
        'x-api-key': this.options.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        Accept: 'text/event-stream'
      },
      body: JSON.stringify(buildAnthropicMessagesRequest(input)),
      ...(this.options.signal ? { signal: this.options.signal } : {})
    });
    if (!response.ok) throw new Error(`Model request failed with ${response.status}: ${(await response.text()).slice(0, 500)}`);
    if (!response.body) throw new Error('Model response did not include a body');
    yield* parseAnthropicMessagesSse(decodeResponseBody(response.body));
  }
}

async function* decodeResponseBody(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) yield decoder.decode(value, { stream: true });
    }
    const tail = decoder.decode();
    if (tail) yield tail;
  } finally {
    reader.releaseLock();
  }
}

async function* asAsync(chunks: Iterable<string> | AsyncIterable<string>): AsyncGenerator<string> {
  if (Symbol.asyncIterator in chunks) yield* chunks as AsyncIterable<string>;
  else yield* chunks as Iterable<string>;
}

interface ToolAccumulator {
  id?: string;
  name?: string;
  initialInput?: string;
  partialInput: string;
}

interface AnthropicSSEPayload {
  type?: string;
  index?: number;
  content_block?: { type?: string; id?: string; name?: string; input?: Record<string, unknown> };
  delta?: { type?: string; text?: string; partial_json?: string };
  message?: { usage?: { input_tokens?: number; cache_read_input_tokens?: number } };
  usage?: { output_tokens?: number };
}

export async function* parseAnthropicMessagesSse(chunks: Iterable<string> | AsyncIterable<string>): AsyncGenerator<ModelEvent> {
  let buffer = '';
  let inputTokens = 0;
  let cachedInputTokens = 0;
  let usageEmitted = false;
  const tools = new Map<number, ToolAccumulator>();

  const flushTool = function* (index: number): Generator<ModelEvent> {
    const tool = tools.get(index);
    if (!tool?.id || !tool.name) return;
    const input = tool.partialInput || tool.initialInput || '{}';
    try { yield { type: 'tool_call', id: tool.id, name: tool.name, arguments: JSON.parse(input) as Record<string, unknown> }; }
    catch { /* Invalid partial tool input remains unavailable to the executor. */ }
  };

  for await (const chunk of asAsync(chunks)) {
    buffer += chunk;
    let boundary = buffer.indexOf('\n\n');
    while (boundary !== -1) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      boundary = buffer.indexOf('\n\n');
      const data = frame.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
      if (!data) continue;
      let payload: AnthropicSSEPayload;
      try { payload = JSON.parse(data) as AnthropicSSEPayload; }
      catch { continue; }

      if (payload.type === 'message_start') {
        inputTokens = payload.message?.usage?.input_tokens ?? 0;
        cachedInputTokens = payload.message?.usage?.cache_read_input_tokens ?? 0;
      } else if (payload.type === 'content_block_start' && typeof payload.index === 'number' && payload.content_block?.type === 'tool_use') {
        const initialInput = payload.content_block.input;
        tools.set(payload.index, { id: payload.content_block.id, name: payload.content_block.name, ...(initialInput && Object.keys(initialInput).length ? { initialInput: JSON.stringify(initialInput) } : {}), partialInput: '' });
      } else if (payload.type === 'content_block_delta') {
        if (payload.delta?.type === 'text_delta' && payload.delta.text) yield { type: 'text_delta', text: payload.delta.text };
        if (typeof payload.index === 'number' && payload.delta?.type === 'input_json_delta') {
          const tool = tools.get(payload.index);
          if (tool) tool.partialInput += payload.delta.partial_json ?? '';
        }
      } else if (payload.type === 'content_block_stop' && typeof payload.index === 'number') {
        yield* flushTool(payload.index);
      } else if (payload.type === 'message_delta') {
        usageEmitted = true;
        yield { type: 'usage', inputTokens, cachedInputTokens, outputTokens: payload.usage?.output_tokens ?? 0 };
      } else if (payload.type === 'message_stop') {
        if (!usageEmitted) yield { type: 'usage', inputTokens, cachedInputTokens, outputTokens: 0 };
        yield { type: 'done' };
        return;
      }
    }
  }
  if (!usageEmitted && (inputTokens || cachedInputTokens)) yield { type: 'usage', inputTokens, cachedInputTokens, outputTokens: 0 };
  yield { type: 'done' };
}
