import { AgentRuntime } from './agent-runtime';
import { buildContext, DEFAULT_CONTEXT_BUDGET, type ContextBudget } from './context-builder';
import type { AgentMode } from './permissions';
import type { AgentToolCall, ModelEvent } from './providers/openai-compatible';
import { ToolExecutionPipeline, type PipelineHooks, type ToolDefinition, type ToolPipelineEvent } from './tool-execution-pipeline';

export interface AgentMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  toolCallId?: string;
  /** assistant 消息携带的工具调用；与后续 tool 消息的 toolCallId 一一配对 */
  toolCalls?: AgentToolCall[];
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
  hooks?: PipelineHooks;
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
    // 8 对"一回合一个工具"风格的模型太紧：read→patch→test→read→patch→test
    // 的修复循环本身就占 7+ 回合（bench:versus 在 deepseek-v4-pro 上实测撞上）。
    // 16 仍是有界上限，失控循环依然会被拦下。
    this.maxTurns = options.maxTurns ?? 16;
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
    // 先补回发起这次调用的 assistant tool_calls 消息，再执行工具：
    // 严格校验的 Provider（Moonshot、Anthropic）会拒绝没有配对 tool_calls 的孤儿 tool 消息。
    messages.push({ role: 'assistant', content: '', toolCalls: [{ id: approved.id, name: approved.tool, arguments: approved.arguments }] });
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
      ...(this.options.hooks ? { hooks: this.options.hooks } : {}),
      onEvent: (event) => this.options.onEvent?.(event)
    });
  }

  private async executeConversation(runtime: AgentRuntime, messages: AgentMessage[], pipeline: ToolExecutionPipeline): Promise<AgentRunResult> {
    let text = '';
    const emit = (event: AgentExecutorEvent): void => this.options.onEvent?.(event);

    try {
      let invokedToolEarlier = false;
      let nudgedEmptyAnswer = false;
      for (let turn = 0; turn < this.maxTurns; turn += 1) {
        const pendingCalls: ToolCallEvent[] = [];
        let turnText = '';
        for await (const event of this.options.model.stream(buildContext(messages, this.options.contextBudget ?? DEFAULT_CONTEXT_BUDGET))) {
          if (event.type === 'text_delta') {
            text += event.text;
            turnText += event.text;
            emit({ type: 'assistant_text', text: event.text });
            continue;
          }
          pendingCalls.push(event);
        }
        if (pendingCalls.length === 0) {
          // Provider 偶发返回空完成（实测 deepseek-v4-pro 出现过一次）：
          // 已经做过工具调用却交白卷时，推送一次追问再放弃，避免把工作沉默地丢掉。
          if (!turnText.trim() && invokedToolEarlier && !nudgedEmptyAnswer) {
            nudgedEmptyAnswer = true;
            messages.push({ role: 'user', content: '（系统提示：你的上一次回答为空。请继续完成任务，或明确说明受阻原因。）' });
            continue;
          }
          runtime.complete();
          emit({ type: 'completed', text });
          if (turnText) messages.push({ role: 'assistant', content: turnText });
          return { text, runtime, messages, status: runtime.state.status };
        }
        // 协议纪律：assistant 的 tool_calls 必须先于对应 tool 结果进入历史。
        invokedToolEarlier = true;
        messages.push({
          role: 'assistant',
          content: turnText,
          toolCalls: pendingCalls.map((call) => ({ id: call.id, name: call.name, arguments: call.arguments }))
        });
        for (const call of pendingCalls) {
          const outcome = await pipeline.execute({ id: call.id, tool: call.name, arguments: call.arguments });
          if (outcome.state === 'awaitingApproval') {
            messages.push({ role: 'tool', content: JSON.stringify({ ok: false, code: 'APPROVAL_REQUIRED' }), toolCallId: call.id });
            return { text, runtime, messages, status: runtime.state.status, pendingApproval: outcome.pending };
          }
          messages.push({ role: 'tool', content: outcome.content, toolCallId: call.id });
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
