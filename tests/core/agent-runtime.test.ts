import { describe, expect, test } from 'vitest';
import { AgentRuntime } from '../../src/core/agent-runtime';

describe('agent runtime', () => {
  test('blocks mutations in plan mode and records a permission event', () => {
    const runtime = new AgentRuntime({ sessionId: 's1', mode: 'plan' });

    const result = runtime.requestTool({ id: 't1', tool: 'apply_patch', mutates: true });

    expect(result.decision).toBe('block');
    expect(runtime.state.status).toBe('planning');
    expect(runtime.events.at(-1)).toMatchObject({ type: 'tool_blocked', tool: 'apply_patch' });
  });

  test('waits for approval before running a command in accept edits mode', () => {
    const runtime = new AgentRuntime({ sessionId: 's1', mode: 'accept_edits' });

    const result = runtime.requestTool({ id: 't1', tool: 'run_command', command: 'npm test', mutates: true });

    expect(result.decision).toBe('ask');
    expect(runtime.state.status).toBe('waiting_approval');
    runtime.resolveApproval('t1', 'allow');
    expect(runtime.state.status).toBe('running');
  });
});
