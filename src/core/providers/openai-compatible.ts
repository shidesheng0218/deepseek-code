import { MODEL_STREAM_TIMEOUT_MS, ModelRequestError, httpError, mergedStreamSignal } from './model-errors';

export interface AgentToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  toolCallId?: string;
  /** assistant 消息携带的工具调用；与后续 tool 消息的 toolCallId 一一配对（严格 Provider 强制要求） */
  toolCalls?: AgentToolCall[];
}

interface OpenAICompatibleMessage {
  role: ChatMessage['role'];
  content: string;
  tool_call_id?: string;
  tool_calls?: Array<{ id: string; type: 'function'; function: { name: string; arguments: string } }>;
}

export interface ChatRequestInput {
  model: string;
  messages: ChatMessage[];
  feature: 'plan' | 'main_agent' | 'explore' | 'review' | 'summary';
  tools: unknown[];
}

export type ModelEvent =
  | { type: 'text_delta'; text: string }
  | { type: 'tool_call'; id: string; name: string; arguments: Record<string, unknown> }
  | { type: 'usage'; inputTokens: number; outputTokens: number; cachedInputTokens: number }
  | { type: 'done' };

export interface OpenAICompatibleRequest {
  model: string;
  messages: OpenAICompatibleMessage[];
  max_tokens: number;
  stream: true;
  stream_options: { include_usage: true };
  tools?: unknown[];
}

export interface OpenAICompatibleClientOptions {
  baseUrl: string;
  apiKey: string;
  fetchImpl?: typeof fetch;
  signal?: AbortSignal;
}

const OUTPUT_CAPS: Record<ChatRequestInput['feature'], number> = {
  plan: 4096,
  main_agent: 8192,
  explore: 2048,
  review: 4096,
  summary: 1024
};

export function buildChatRequest(input: ChatRequestInput): OpenAICompatibleRequest {
  const request: OpenAICompatibleRequest = {
    model: input.model,
    messages: input.messages.map((message) => ({
      role: message.role,
      content: message.content,
      ...(message.toolCallId === undefined ? {} : { tool_call_id: message.toolCallId }),
      ...(message.role === 'assistant' && message.toolCalls?.length
        ? {
            tool_calls: message.toolCalls.map((call) => ({
              id: call.id,
              type: 'function' as const,
              function: { name: call.name, arguments: JSON.stringify(call.arguments) }
            }))
          }
        : {})
    })),
    max_tokens: OUTPUT_CAPS[input.feature],
    stream: true,
    stream_options: { include_usage: true }
  };
  if (input.tools.length > 0) request.tools = input.tools;
  return request;
}

export class OpenAICompatibleClient {
  private readonly endpoint: URL;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly options: OpenAICompatibleClientOptions) {
    const baseUrl = options.baseUrl.endsWith('/') ? options.baseUrl : `${options.baseUrl}/`;
    this.endpoint = new URL('chat/completions', baseUrl);
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async *stream(input: ChatRequestInput): AsyncGenerator<ModelEvent> {
    const { signal, isTimeout } = mergedStreamSignal(this.options.signal, MODEL_STREAM_TIMEOUT_MS);
    let response: Response;
    try {
      response = await this.fetchImpl(this.endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.options.apiKey}`,
          'Content-Type': 'application/json',
          Accept: 'text/event-stream'
        },
        body: JSON.stringify(buildChatRequest(input)),
        signal
      });
    } catch (error) {
      if (this.options.signal?.aborted) throw error; // 用户主动取消：原样传播，不包装、不重试
      if (isTimeout()) throw new ModelRequestError(`Model request timed out after ${MODEL_STREAM_TIMEOUT_MS}ms`, 'timeout', true);
      throw new ModelRequestError(error instanceof Error ? error.message : String(error), 'network_error', true);
    }
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 500);
      throw httpError(response.status, detail);
    }
    if (!response.body) throw new Error('Model response did not include a body');
    try {
      yield* parseOpenAICompatibleSse(decodeResponseBody(response.body));
    } catch (error) {
      if (!this.options.signal?.aborted && isTimeout()) throw new ModelRequestError(`Model stream timed out after ${MODEL_STREAM_TIMEOUT_MS}ms`, 'timeout', true);
      throw error;
    }
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
  if (Symbol.asyncIterator in chunks) {
    yield* chunks as AsyncIterable<string>;
    return;
  }
  yield* chunks as Iterable<string>;
}

interface ToolAccumulator {
  id?: string;
  name?: string;
  argumentsText: string;
}

interface SseToolCallDelta {
  index: number;
  id?: string;
  function?: { name?: string; arguments?: string };
}

interface SsePayload {
  choices?: Array<{
    delta?: {
      content?: string;
      tool_calls?: SseToolCallDelta[];
    };
  }>;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    prompt_tokens_details?: { cached_tokens?: number };
  };
}

export async function* parseOpenAICompatibleSse(chunks: Iterable<string> | AsyncIterable<string>): AsyncGenerator<ModelEvent> {
  let buffer = '';
  const tools = new Map<number, ToolAccumulator>();

  const flushTools = function* (): Generator<ModelEvent> {
    for (const tool of tools.values()) {
      if (!tool.id || !tool.name) continue;
      try {
        const argumentsObject = JSON.parse(tool.argumentsText) as Record<string, unknown>;
        yield { type: 'tool_call', id: tool.id, name: tool.name, arguments: argumentsObject };
      } catch {
        // flush 发生在流结束时，此时参数已完整；解析失败即真实损坏。
        // 静默丢弃会让 executor 把"工具意图蒸发"当作正常完成收场，
        // 必须显式失败，由上层以明确错误结束本轮（不执行任何不完整操作）。
        throw new ModelRequestError(`Model returned malformed tool call arguments for "${tool.name}"`, 'malformed_tool_arguments', false);
      }
    }
  };

  for await (const chunk of asAsync(chunks)) {
    buffer += chunk;
    let boundary = buffer.indexOf('\n\n');
    while (boundary !== -1) {
      const frame = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      boundary = buffer.indexOf('\n\n');

      const data = frame
        .split('\n')
        .filter((line) => line.startsWith('data:'))
        .map((line) => line.slice(5).trim())
        .join('\n');
      if (!data) continue;
      if (data === '[DONE]') {
        yield* flushTools();
        yield { type: 'done' };
        return;
      }

      let payload: SsePayload;
      try {
        payload = JSON.parse(data) as SsePayload;
      } catch {
        continue;
      }

      const delta = payload.choices?.[0]?.delta;
      if (delta?.content) yield { type: 'text_delta', text: delta.content };
      for (const call of delta?.tool_calls ?? []) {
        const existing = tools.get(call.index) ?? { argumentsText: '' };
        if (call.id) existing.id = call.id;
        if (call.function?.name) existing.name = call.function.name;
        existing.argumentsText += call.function?.arguments ?? '';
        tools.set(call.index, existing);
      }
      if (payload.usage) {
        yield {
          type: 'usage',
          inputTokens: payload.usage.prompt_tokens ?? 0,
          outputTokens: payload.usage.completion_tokens ?? 0,
          cachedInputTokens: payload.usage.prompt_tokens_details?.cached_tokens ?? 0
        };
      }
    }
  }

  yield* flushTools();
  yield { type: 'done' };
}
