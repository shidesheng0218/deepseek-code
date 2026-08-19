import { AgentRuntime } from './agent-runtime';
import { buildContext, DEFAULT_CONTEXT_BUDGET, type ContextBudget } from './context-builder';
import type { AgentMode } from './permissions';
import type { ModelEvent } from './providers/openai-compatible';
import { ToolExecutionPipeline, type ToolDefinition, type ToolPipelineEvent } from './tool-execution-pipeline';

export interface AgentMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  toolCallId?: string;
}

export interface ApprovedToolCall {
  id: string;
  tool: string;
  arguments: Record<string, unknown>;
}

export interface AgentRunResult {
  text: string;
  runtime: AgentRuntime;
  messages: AgentMessage[];
  status: AgentRuntime['state']['status'];
  pendingApproval?: ApprovedToolCall & { risk: string };
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
  instructions?: string;
  model: { stream: (messages: AgentMessage[]) => AsyncIterable<ExecutorEvent> };
  tools: Record<string, (input: Record<string, unknown>) => Promise<unknown>>;
  toolDefinitions?: Record<string, ToolDefinition>;
  maxTurns?: number;
  contextBudget?: ContextBudget;
  onEvent?: (event: AgentExecutorEvent) => void;
}

export type AgentExecutorEvent = ToolPipelineEvent
  | { type: 'assistant_text'; text: string }
  | { type: 'completed'; text: string }
  | { type: 'failed'; error: string };

function defaultToolDefinitions(tools: Record<string, (input: Record<string, unknown>) => Promise<unknown>>): Record<string, ToolDefinition> {
  return Object.fromEntries(Object.keys(tools).map((name) => [name, { name, mutates: name === 'apply_patch' || name === 'git_action' || name === 'run_command' }]));
}

export class AgentExecutor {
  private readonly maxTurns: number;

  constructor(private readonly options: AgentExecutorOptions) {
    this.maxTurns = options.maxTurns ?? 8;
  }

  async run(sessionId: string, prompt: string, history: AgentMessage[] = []): Promise<AgentRunResult> {
    const runtime = new AgentRuntime({ sessionId, mode: this.options.mode });
    const messages: AgentMessage[] = [
      ...(this.options.instructions ? [{ role: 'system' as const, content: this.options.instructions }] : []),
      ...history,
      { role: 'user', content: prompt }
    ];
    return this.executeConversation(runtime, messages, this.createPipeline(runtime));
  }

  async resume(sessionId: string, history: AgentMessage[], approved: ApprovedToolCall): Promise<AgentRunResult> {
    const runtime = new AgentRuntime({ sessionId, mode: this.options.mode });
    const messages: AgentMessage[] = [
      ...(this.options.instructions ? [{ role: 'system' as const, content: this.options.instructions }] : []),
      ...history
    ];
    const pipeline = this.createPipeline(runtime);
    const outcome = await pipeline.executeApproved(approved);
    if (outcome.state !== 'completed') throw new Error('Approved tool execution unexpectedly requested approval');
    messages.push({ role: 'tool', content: outcome.content, toolCallId: approved.id });
    return this.executeConversation(runtime, messages, pipeline);
  }

  private createPipeline(runtime: AgentRuntime): ToolExecutionPipeline {
    return new ToolExecutionPipeline({
      runtime,
      tools: this.options.tools,
      definitions: { ...defaultToolDefinitions(this.options.tools), ...this.options.toolDefinitions },
      onEvent: (event) => this.options.onEvent?.(event)
    });
  }

  private async executeConversation(runtime: AgentRuntime, messages: AgentMessage[], pipeline: ToolExecutionPipeline): Promise<AgentRunResult> {
    let text = '';
    const emit = (event: AgentExecutorEvent): void => this.options.onEvent?.(event);

    try {
      for (let turn = 0; turn < this.maxTurns; turn += 1) {
        let invokedTool = false;
        for await (const event of this.options.model.stream(buildContext(messages, this.options.contextBudget ?? DEFAULT_CONTEXT_BUDGET))) {
          if (event.type === 'text_delta') {
            text += event.text;
            emit({ type: 'assistant_text', text: event.text });
            continue;
          }
          invokedTool = true;
          const outcome = await pipeline.execute({ id: event.id, tool: event.name, arguments: event.arguments });
          if (outcome.state === 'awaitingApproval') {
            messages.push({ role: 'tool', content: JSON.stringify({ ok: false, code: 'APPROVAL_REQUIRED' }), toolCallId: event.id });
            return { text, runtime, messages, status: runtime.state.status, pendingApproval: outcome.pending };
          }
          messages.push({ role: 'tool', content: outcome.content, toolCallId: event.id });
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
