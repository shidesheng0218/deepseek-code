import { AgentRuntime } from './agent-runtime';

export interface ToolDefinition {
  name: string;
  mutates?: boolean;
  timeoutMs?: number;
  inputSchema?: { required?: string[] };
}

export interface ToolInvocation {
  id: string;
  tool: string;
  arguments: Record<string, unknown>;
}

export interface PendingToolApproval extends ToolInvocation { risk: string }

export type ToolPipelineEvent =
  | { type: 'tool_requested'; id: string; tool: string; risk: string }
  | { type: 'tool_started'; id: string; tool: string }
  | { type: 'tool_completed'; id: string; tool: string; ok: boolean; output?: string; error?: string }
  | { type: 'tool_indeterminate'; id: string; tool: string; error: string }
  | { type: 'approval_required'; id: string; tool: string; risk: string };

export type ToolPipelineResult =
  | { state: 'completed'; content: string }
  | { state: 'awaitingApproval'; pending: PendingToolApproval };

interface ToolExecutionPipelineOptions {
  runtime: AgentRuntime;
  tools: Record<string, (input: Record<string, unknown>) => Promise<unknown>>;
  definitions?: Record<string, ToolDefinition>;
  onEvent?: (event: ToolPipelineEvent) => void;
}

function serialize(result: unknown): string {
  if (typeof result === 'string') return result;
  if (result && typeof result === 'object' && 'content' in result && typeof result.content === 'string') return result.content;
  return JSON.stringify(result);
}

function errorContent(code: string, message?: string): string {
  return JSON.stringify({ ok: false, code, ...(message ? { message } : {}) });
}

function validationError(definition: ToolDefinition | undefined, argumentsValue: Record<string, unknown>): string | undefined {
  for (const field of definition?.inputSchema?.required ?? []) {
    if (argumentsValue[field] === undefined || argumentsValue[field] === null) return `Missing required tool argument: ${field}`;
  }
  return undefined;
}

class TimeoutError extends Error {}

async function withTimeout<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<T>((_, reject) => { timer = setTimeout(() => reject(new TimeoutError(`Tool timed out after ${timeoutMs}ms`)), timeoutMs); })
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export class ToolExecutionPipeline {
  constructor(private readonly options: ToolExecutionPipelineOptions) {}

  async execute(invocation: ToolInvocation): Promise<ToolPipelineResult> {
    const definition = this.options.definitions?.[invocation.tool];
    const invalid = validationError(definition, invocation.arguments);
    if (invalid) {
      const content = errorContent('TOOL_VALIDATION_ERROR', invalid);
      this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: false, error: invalid });
      return { state: 'completed', content };
    }
    const command = typeof invocation.arguments.command === 'string' ? invocation.arguments.command : undefined;
    const decision = this.options.runtime.requestTool({
      id: invocation.id,
      tool: invocation.tool,
      ...(command === undefined ? {} : { command }),
      mutates: definition?.mutates ?? false
    });
    this.emit({ type: 'tool_requested', id: invocation.id, tool: invocation.tool, risk: decision.risk });
    if (decision.decision === 'ask') {
      this.emit({ type: 'approval_required', id: invocation.id, tool: invocation.tool, risk: decision.risk });
      return { state: 'awaitingApproval', pending: { ...invocation, risk: decision.risk } };
    }
    if (decision.decision === 'block') return { state: 'completed', content: errorContent('POLICY_BLOCKED') };
    return this.invokeHost(invocation, definition);
  }

  async executeApproved(invocation: ToolInvocation): Promise<ToolPipelineResult> {
    const definition = this.options.definitions?.[invocation.tool];
    const invalid = validationError(definition, invocation.arguments);
    if (invalid) {
      const content = errorContent('TOOL_VALIDATION_ERROR', invalid);
      this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: false, error: invalid });
      return { state: 'completed', content };
    }
    return this.invokeHost(invocation, definition);
  }

  private async invokeHost(invocation: ToolInvocation, definition: ToolDefinition | undefined): Promise<ToolPipelineResult> {
    const host = this.options.tools[invocation.tool];
    if (!host) {
      const content = errorContent('TOOL_NOT_FOUND', invocation.tool);
      this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: false, output: content });
      return { state: 'completed', content };
    }
    this.emit({ type: 'tool_started', id: invocation.id, tool: invocation.tool });
    try {
      const rawResult = await withTimeout(host(invocation.arguments), definition?.timeoutMs ?? 120_000);
      const output = serialize(rawResult);
      if (rawResult && typeof rawResult === 'object' && 'indeterminate' in rawResult && rawResult.indeterminate === true) {
        const error = 'output' in rawResult && typeof rawResult.output === 'string' ? rawResult.output : 'Tool result is indeterminate';
        this.emit({ type: 'tool_indeterminate', id: invocation.id, tool: invocation.tool, error });
        return { state: 'completed', content: output };
      }
      if (rawResult && typeof rawResult === 'object' && 'ok' in rawResult && rawResult.ok === false) {
        const error = 'error' in rawResult && typeof rawResult.error === 'string' ? rawResult.error : 'Tool returned a failure';
        this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: false, error, output });
        return { state: 'completed', content: output };
      }
      this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: true, output });
      return { state: 'completed', content: output };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (error instanceof TimeoutError) {
        const content = errorContent('TOOL_INDETERMINATE', message);
        this.emit({ type: 'tool_indeterminate', id: invocation.id, tool: invocation.tool, error: message });
        return { state: 'completed', content };
      }
      const content = errorContent('TOOL_ERROR', message);
      this.emit({ type: 'tool_completed', id: invocation.id, tool: invocation.tool, ok: false, error: message });
      return { state: 'completed', content };
    }
  }

  private emit(event: ToolPipelineEvent): void { this.options.onEvent?.(event); }
}
