import { describe, expect, test } from 'vitest';
import { AgentRuntime } from '../../src/core/agent-runtime';
import { ToolExecutionPipeline, type ToolPipelineEvent } from '../../src/core/tool-execution-pipeline';

describe('pipeline hooks', () => {
  test('preToolUse block prevents host execution and emits a failure event', async () => {
    let hostCalled = false;
    const events: ToolPipelineEvent[] = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: { list_directory: async () => { hostCalled = true; return { entries: [] }; } },
      definitions: { list_directory: { name: 'list_directory', mutates: false } },
      hooks: {
        preToolUse: async (invocation) => invocation.tool === 'list_directory' ? { blocked: '项目策略：禁止列目录' } : undefined
      },
      onEvent: (event) => events.push(event)
    });

    const outcome = await pipeline.execute({ id: 'c1', tool: 'list_directory', arguments: {} });
    expect(outcome.state).toBe('completed');
    if (outcome.state === 'completed') expect(outcome.content).toContain('HOOK_BLOCKED');
    expect(hostCalled).toBe(false);
    const completed = events.find((event) => event.type === 'tool_completed');
    expect(completed && 'error' in completed ? completed.error : '').toContain('禁止列目录');
    expect(events.some((event) => event.type === 'tool_started')).toBe(false);
  });

  test('postToolUse observes success and failure without changing the result', async () => {
    const seen: Array<{ tool: string; ok: boolean }> = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: {
        ok_tool: async () => 'done',
        bad_tool: async () => { throw new Error('kaput'); }
      },
      definitions: { ok_tool: { name: 'ok_tool' }, bad_tool: { name: 'bad_tool' } },
      hooks: {
        postToolUse: async (invocation, outcome) => { seen.push({ tool: invocation.tool, ok: outcome.ok }); }
      }
    });

    await pipeline.execute({ id: 'c1', tool: 'ok_tool', arguments: {} });
    await pipeline.execute({ id: 'c2', tool: 'bad_tool', arguments: {} });
    expect(seen).toEqual([{ tool: 'ok_tool', ok: true }, { tool: 'bad_tool', ok: false }]);
  });

  test('a throwing postToolUse hook never breaks tool execution', async () => {
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'auto' }),
      tools: { ok_tool: async () => 'done' },
      hooks: { postToolUse: async () => { throw new Error('hook crashed'); } }
    });
    const outcome = await pipeline.execute({ id: 'c1', tool: 'ok_tool', arguments: {} });
    expect(outcome.state).toBe('completed');
    if (outcome.state === 'completed') expect(outcome.content).toBe('done');
  });
});
