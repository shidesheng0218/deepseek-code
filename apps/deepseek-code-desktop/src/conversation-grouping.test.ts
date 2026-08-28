import { describe, expect, it } from 'vitest';
import { groupConversation, groupSessionsByProject, projectGroupName, type Message, type SessionSummary } from './conversation-grouping';

describe('groupConversation', () => {
  it('keeps a single user/assistant exchange as two separate items', () => {
    const messages: Message[] = [
      { role: 'user', text: 'fix the bug' },
      { role: 'assistant', text: 'done' },
    ];
    const items = groupConversation(messages);
    expect(items).toHaveLength(2);
    expect(items[0]).toMatchObject({ kind: 'message', message: { role: 'user' } });
    expect(items[1]).toMatchObject({ kind: 'message', message: { role: 'assistant' } });
  });

  it('collapses consecutive tool-activity messages into a single toolGroup', () => {
    const messages: Message[] = [
      { role: 'user', text: 'run the tests' },
      { role: 'tool', text: 'started', kind: 'tool_started' },
      { role: 'tool', text: 'ran command', kind: 'terminal_completed' },
      { role: 'tool', text: 'finished', kind: 'tool_completed' },
      { role: 'assistant', text: 'tests pass' },
    ];
    const items = groupConversation(messages);
    expect(items.map((item) => item.kind)).toEqual(['message', 'toolGroup', 'message']);
    const toolGroup = items[1];
    if (toolGroup.kind !== 'toolGroup') throw new Error('expected a toolGroup');
    expect(toolGroup.activities).toHaveLength(3);
  });

  it('does not group a tool message whose kind is not in TOOL_ACTIVITY_KINDS', () => {
    // e.g. an error surfaced as role "tool" but not one of the recognised activity kinds
    const messages: Message[] = [{ role: 'tool', text: 'unexpected', kind: 'something_else' }];
    const items = groupConversation(messages);
    expect(items).toEqual([{ key: 'msg-0', kind: 'message', message: messages[0] }]);
  });

  it('flushes a trailing tool group even with no message after it', () => {
    const messages: Message[] = [
      { role: 'user', text: 'go' },
      { role: 'tool', text: 'working', kind: 'tool_started' },
    ];
    const items = groupConversation(messages);
    expect(items.map((item) => item.kind)).toEqual(['message', 'toolGroup']);
  });

  it('returns an empty list for an empty conversation', () => {
    expect(groupConversation([])).toEqual([]);
  });
});

describe('projectGroupName', () => {
  it('extracts the last path segment as the display name', () => {
    expect(projectGroupName('/Users/you/Projects/my-app')).toBe('my-app');
  });

  it('handles a trailing slash without leaving an empty name', () => {
    expect(projectGroupName('/Users/you/Projects/my-app/')).toBe('my-app');
  });

  it('falls back to "未关联项目" for an empty path — sessions started before a project was configured', () => {
    expect(projectGroupName('')).toBe('未关联项目');
  });
});

describe('groupSessionsByProject', () => {
  const session = (sessionId: string, projectPath: string): SessionSummary => ({ sessionId, title: sessionId, updatedAt: 0, projectPath });

  it('groups sessions that share the same project directory together', () => {
    const sessions = [session('a', '/Users/you/app'), session('b', '/Users/you/app'), session('c', '/Users/you/other')];
    const groups = groupSessionsByProject(sessions);
    expect(groups).toHaveLength(2);
    const appGroup = groups.find((g) => g.name === 'app');
    expect(appGroup?.sessions.map((s) => s.sessionId)).toEqual(['a', 'b']);
  });

  it('returns an empty array for no sessions', () => {
    expect(groupSessionsByProject([])).toEqual([]);
  });
});
