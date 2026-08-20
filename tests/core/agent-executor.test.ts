import { describe, expect, test } from 'vitest';
import { AgentExecutor, type AgentMessage } from '../../src/core/agent-executor';

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

  test('adds stable agent instructions before conversation history', async () => {
    let received: Array<{ role: string; content: string }> = [];
    const executor = new AgentExecutor({
      mode: 'auto',
      instructions: '你是一个严谨的本地编码助手。',
      model: { stream: async function* (messages) { received = messages.map((message) => ({ role: message.role, content: message.content })); yield { type: 'text_delta', text: '好的' } as const; } },
      tools: {}
    });

    await executor.run('s1', '继续', [{ role: 'user', content: '之前的问题' }]);

    expect(received).toEqual([
      { role: 'system', content: '你是一个严谨的本地编码助手。' },
      { role: 'user', content: '之前的问题' },
      { role: 'user', content: '继续' }
    ]);
  });

  test('pairs assistant tool_calls with tool results for strict providers (Moonshot/Anthropic)', async () => {
    let secondRequest: AgentMessage[] = [];
    let call = 0;
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: {
        stream: async function* (messages) {
          call += 1;
          if (call === 1) {
            yield { type: 'tool_call', id: 'read-1', name: 'read_file', arguments: { path: 'README.md' } } as const;
            yield { type: 'tool_call', id: 'read-2', name: 'read_file', arguments: { path: 'package.json' } } as const;
          } else {
            secondRequest = [...messages];
            yield { type: 'text_delta', text: '完成' } as const;
          }
        }
      },
      tools: { read_file: async () => 'content' }
    });

    await executor.run('s1', '读取两个文件');

    const assistantIndex = secondRequest.findIndex((message) => message.role === 'assistant' && message.toolCalls?.length);
    expect(assistantIndex).toBeGreaterThanOrEqual(0);
    expect(secondRequest[assistantIndex]?.toolCalls).toEqual([
      { id: 'read-1', name: 'read_file', arguments: { path: 'README.md' } },
      { id: 'read-2', name: 'read_file', arguments: { path: 'package.json' } }
    ]);
    const results = secondRequest.slice(assistantIndex + 1).filter((message) => message.role === 'tool');
    expect(results.map((message) => message.toolCallId)).toEqual(['read-1', 'read-2']);
  });

  test('resume backfills the assistant tool_calls message before the approved tool result', async () => {
    let received: AgentMessage[] = [];
    const executor = new AgentExecutor({
      mode: 'manual',
      model: { stream: async function* (messages) { received = [...messages]; yield { type: 'text_delta', text: '已确认' } as const; } },
      tools: { apply_patch: async () => 'changed' }
    });

    await executor.resume('s1', [{ role: 'user', content: '修改 README' }], {
      id: 'patch-1', tool: 'apply_patch', arguments: { changes: [{ path: 'README.md', content: 'next' }] }
    });

    const assistantIndex = received.findIndex((message) => message.role === 'assistant' && message.toolCalls?.length);
    expect(assistantIndex).toBeGreaterThanOrEqual(0);
    expect(received[assistantIndex]?.toolCalls).toEqual([{ id: 'patch-1', name: 'apply_patch', arguments: { changes: [{ path: 'README.md', content: 'next' }] } }]);
    expect(received[assistantIndex + 1]).toMatchObject({ role: 'tool', toolCallId: 'patch-1' });
  });

  test('nudges once when the provider returns an empty answer after tool work', async () => {
    let call = 0;
    const seen: Array<Array<{ role: string; content: string }>> = [];
    const executor = new AgentExecutor({
      mode: 'accept_edits',
      model: {
        stream: async function* (messages) {
          seen.push(messages.map((message) => ({ role: message.role, content: message.content })));
          call += 1;
          if (call === 1) yield { type: 'tool_call', id: 'read-1', name: 'read_file', arguments: { path: 'a.ts' } } as const;
          else if (call === 2) return; // 空完成：Provider 偶发行为
          else yield { type: 'text_delta', text: '修复完成' } as const;
        }
      },
      tools: { read_file: async () => '内容' }
    });

    const result = await executor.run('s1', '读取并修复');

    expect(result.status).toBe('completed');
    expect(result.text).toBe('修复完成');
    const nudge = seen[2]?.find((message) => message.role === 'user' && message.content.includes('上一次回答为空'));
    expect(nudge).toBeTruthy();
  });
});
