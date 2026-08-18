import { AgentRuntime } from './agent-runtime';
import type { AgentMode } from './permissions';
import type { ModelEvent } from './providers/openai-compatible';

export interface AgentMessage {
  role: 'user' | 'assistant' | 'tool';
  content: string;
  toolCallId?: string;
}

interface ToolCallEvent {
  type: 'tool_call';
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

type ExecutorEvent = Extract<ModelEvent, { type: 'text_delta' }> | ToolCallEvent;

export interface AgentExecutorOptions {
  mode: AgentMode;
  model: { stream: (messages: AgentMessage[]) => AsyncIterable<ExecutorEvent> };
  tools: Record<string, (input: Record<string, unknown>) => Promise<unknown>>;
  maxTurns?: number;
  onEvent?: (event: AgentExecutorEvent) => void;
}

export type AgentExecutorEvent =
  | { type: 'tool_requested'; id: string; tool: string; risk: string }
  | { type: 'tool_started'; id: string; tool: string }
  | { type: 'tool_completed'; id: string; tool: string; ok: boolean; output?: string; error?: string }
  | { type: 'approval_required'; id: string; tool: string; risk: string }
  | { type: 'assistant_text'; text: string }
  | { type: 'completed'; text: string }
  | { type: 'failed'; error: string };

function isMutatingTool(name: string): boolean {
  return name === 'apply_patch' || name === 'git_action' || name === 'run_command';
}

function serializeToolResult(result: unknown): string {
  if (typeof result === 'string') return result;
  if (result && typeof result === 'object' && 'content' in result && typeof result.content === 'string') return result.content;
  return JSON.stringify(result);
}

export class AgentExecutor {
  private readonly maxTurns: number;

  constructor(private readonly options: AgentExecutorOptions) {
    this.maxTurns = options.maxTurns ?? 8;
  }

  async run(sessionId: string, prompt: string, history: AgentMessage[] = []): Promise<{ text: string; runtime: AgentRuntime; messages: AgentMessage[]; status: AgentRuntime['state']['status'] }> {
    const runtime = new AgentRuntime({ sessionId, mode: this.options.mode });
    const messages: AgentMessage[] = [...history, { role: 'user', content: prompt }];
    let text = '';
    const emit = (event: AgentExecutorEvent): void => this.options.onEvent?.(event);

    try {
      for (let turn = 0; turn < this.maxTurns; turn += 1) {
        let invokedTool = false;
        for await (const event of this.options.model.stream(messages)) {
          if (event.type === 'text_delta') {
            text += event.text;
            emit({ type: 'assistant_text', text: event.text });
            continue;
          }
          invokedTool = true;
          const command = typeof event.arguments.command === 'string' ? event.arguments.command : undefined;
          const decision = runtime.requestTool({ id: event.id, tool: event.name, ...(command === undefined ? {} : { command }), mutates: isMutatingTool(event.name) });
          emit({ type: 'tool_requested', id: event.id, tool: event.name, risk: decision.risk });
          if (decision.decision !== 'allow') {
            const code = decision.decision === 'ask' ? 'APPROVAL_REQUIRED' : 'POLICY_BLOCKED';
            messages.push({ role: 'tool', content: JSON.stringify({ ok: false, code }), toolCallId: event.id });
            if (decision.decision === 'ask') {
              emit({ type: 'approval_required', id: event.id, tool: event.name, risk: decision.risk });
              return { text, runtime, messages, status: runtime.state.status };
            }
            continue;
          }
          const tool = this.options.tools[event.name];
          if (!tool) {
            const content = JSON.stringify({ ok: false, code: 'TOOL_NOT_FOUND', tool: event.name });
            messages.push({ role: 'tool', content, toolCallId: event.id });
            emit({ type: 'tool_completed', id: event.id, tool: event.name, ok: false, output: content });
            continue;
          }
          emit({ type: 'tool_started', id: event.id, tool: event.name });
          try {
            const output = serializeToolResult(await tool(event.arguments));
            messages.push({ role: 'tool', content: output, toolCallId: event.id });
            emit({ type: 'tool_completed', id: event.id, tool: event.name, ok: true, output });
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            const content = JSON.stringify({ ok: false, code: 'TOOL_ERROR', message });
            messages.push({ role: 'tool', content, toolCallId: event.id });
            emit({ type: 'tool_completed', id: event.id, tool: event.name, ok: false, error: message });
          }
        }
        if (!invokedTool) {
          runtime.complete();
          emit({ type: 'completed', text });
          if (text) messages.push({ role: 'assistant', content: text });
          return { text, runtime, messages, status: runtime.state.status };
        }
      }
      throw new Error(`Agent exceeded ${this.maxTurns} tool turns`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      emit({ type: 'failed', error: message });
      throw error;
    }
  }
}
