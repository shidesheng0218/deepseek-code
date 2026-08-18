import { describe, expect, test } from 'vitest';
import { AgentExecutor } from '../../src/core/agent-executor';

describe('agent executor', () => {
  test('emits an auditable event for each tool and completes after the model responds', async () => {
    const events: string[] = [];
    let call = 0;
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: {
        stream: async function* () {
          call += 1;
          if (call === 1) yield { type: 'tool_call', id: 'read-1', name: 'read_file', arguments: { path: 'README.md' } } as const;
          else yield { type: 'text_delta', text: '完成' } as const;
        }
      },
      tools: { read_file: async () => 'README content' },
      onEvent: (event) => events.push(event.type)
    });

    await executor.run('s1', '读取 README');

    expect(events).toEqual(['tool_requested', 'tool_started', 'tool_completed', 'assistant_text', 'completed']);
  });

  test('stops at an approval request instead of pretending the tool ran', async () => {
    const executor = new AgentExecutor({
      mode: 'manual',
      model: { stream: async function* () { yield { type: 'tool_call', id: 'patch-1', name: 'apply_patch', arguments: {} } as const; } },
      tools: { apply_patch: async () => 'changed' }
    });

    const result = await executor.run('s1', '修改文件');

    expect(result.status).toBe('waiting_approval');
    expect(result.messages.at(-1)?.content).toContain('APPROVAL_REQUIRED');
  });

  test('passes command text into the permission classifier before execution', async () => {
    const executor = new AgentExecutor({
      mode: 'auto',
      model: { stream: async function* () { yield { type: 'tool_call', id: 'cmd-1', name: 'run_command', arguments: { command: 'npm install react' } } as const; } },
      tools: { run_command: async () => 'installed' }
    });

    const result = await executor.run('s1', '安装依赖');

    expect(result.status).toBe('waiting_approval');
  });

  test('feeds a tool result back into the model before completing the task', async () => {
    const requests: Array<{ role: string; content: string }> = [];
    let call = 0;
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: {
        stream: async function* (messages) {
          requests.push(...messages.filter((message) => message.role === 'tool' || message.role === 'user'));
          call += 1;
          if (call === 1) yield { type: 'tool_call', id: 'read-1', name: 'read_file', arguments: { path: 'README.md' } } as const;
          else yield { type: 'text_delta', text: '已读取 README，任务可以继续。' } as const;
        }
      },
      tools: {
        read_file: async (input) => ({ ok: true, content: `content:${String(input.path)}` })
      }
    });

    const result = await executor.run('s1', '读取 README 并总结项目');

    expect(result.text).toContain('已读取 README');
    expect(requests).toContainEqual({ role: 'tool', content: 'content:README.md', toolCallId: 'read-1' });
  });

  test('marks a completed answer as completed instead of leaving the session in planning', async () => {
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: { stream: async function* () { yield { type: 'text_delta', text: '完成' } as const; } },
      tools: {}
    });

    const result = await executor.run('s1', '回答问题');

    expect(result.status).toBe('completed');
  });

  test('includes committed conversation history in the next model request', async () => {
    let received: Array<{ role: string; content: string }> = [];
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: { stream: async function* (messages) { received = [...messages]; yield { type: 'text_delta', text: '下一轮回答' } as const; } },
      tools: {}
    });

    await executor.run('s1', '第二个问题', [{ role: 'user', content: '第一个问题' }, { role: 'assistant', content: '第一个回答' }]);

    expect(received).toEqual([
      { role: 'user', content: '第一个问题' },
      { role: 'assistant', content: '第一个回答' },
      { role: 'user', content: '第二个问题' }
    ]);
  });

  test('resumes an approved tool call and continues the same model conversation', async () => {
    const events: string[] = [];
    const calls: Array<{ role: string; content: string; toolCallId?: string }> = [];
    const executor = new AgentExecutor({
      mode: 'manual',
      model: {
        stream: async function* (messages) {
          calls.push(...messages);
          yield { type: 'text_delta', text: '工具结果已确认' } as const;
        }
      },
      tools: { apply_patch: async () => ({ changedFiles: ['README.md'] }) },
      onEvent: (event) => events.push(event.type)
    });

    const result = await executor.resume('s1', [{ role: 'user', content: '修改 README' }], {
      id: 'patch-1', tool: 'apply_patch', arguments: { changes: [{ path: 'README.md', content: 'next' }] }
    });

    expect(result.status).toBe('completed');
    expect(calls).toContainEqual({ role: 'tool', toolCallId: 'patch-1', content: JSON.stringify({ changedFiles: ['README.md'] }) });
    expect(events).toEqual(['tool_started', 'tool_completed', 'assistant_text', 'completed']);
  });
});
