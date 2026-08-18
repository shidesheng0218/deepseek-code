import { describe, expect, test, vi } from 'vitest';
import { AgentRuntime } from '../../src/core/agent-runtime';
import { ToolExecutionPipeline } from '../../src/core/tool-execution-pipeline';

describe('ToolExecutionPipeline', () => {
  test('validates required arguments before invoking a tool host', async () => {
    const host = vi.fn(async () => 'changed');
    const events: string[] = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: { apply_patch: host },
      definitions: { apply_patch: { name: 'apply_patch', mutates: true, inputSchema: { required: ['changes'] } } },
      onEvent: (event) => events.push(event.type)
    });

    const result = await pipeline.execute({ id: 'patch-1', tool: 'apply_patch', arguments: {} });

    expect(result).toMatchObject({ state: 'completed', content: expect.stringContaining('TOOL_VALIDATION_ERROR') });
    expect(host).not.toHaveBeenCalled();
    expect(events).toEqual(['tool_completed']);
  });

  test('returns an approval continuation without executing a gated tool', async () => {
    const host = vi.fn(async () => 'changed');
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'manual' }),
      tools: { apply_patch: host },
      definitions: { apply_patch: { name: 'apply_patch', mutates: true } }
    });

    const result = await pipeline.execute({ id: 'patch-1', tool: 'apply_patch', arguments: { changes: [] } });

    expect(result).toMatchObject({ state: 'awaitingApproval', pending: { id: 'patch-1', tool: 'apply_patch' } });
    expect(host).not.toHaveBeenCalled();
  });

  test('marks a timed-out tool as indeterminate instead of a retryable failure', async () => {
    const events: string[] = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: { read_file: async () => await new Promise<string>(() => undefined) },
      definitions: { read_file: { name: 'read_file', timeoutMs: 5 } },
      onEvent: (event) => events.push(event.type)
    });

    const result = await pipeline.execute({ id: 'read-1', tool: 'read_file', arguments: {} });

    expect(result).toMatchObject({ state: 'completed', content: expect.stringContaining('TOOL_INDETERMINATE') });
    expect(events).toEqual(['tool_requested', 'tool_started', 'tool_indeterminate']);
  });

  test('preserves structured indeterminate results returned by a remote host', async () => {
    const events: string[] = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: { remote_tool: async () => ({ ok: false, output: 'connection lost', indeterminate: true }) },
      definitions: { remote_tool: { name: 'remote_tool', mutates: false } },
      onEvent: (event) => events.push(event.type)
    });

    const result = await pipeline.execute({ id: 'ssh-1', tool: 'remote_tool', arguments: {} });

    expect(result).toMatchObject({ state: 'completed', content: expect.stringContaining('connection lost') });
    expect(events).toEqual(['tool_requested', 'tool_started', 'tool_indeterminate']);
  });
});
