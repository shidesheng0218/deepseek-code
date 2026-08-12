import { describe, expect, test } from 'vitest';
import { SessionEventStore } from '../../src/core/persistence/session-store';

describe('SQLite session event store', () => {
  test('persists ordered events and reconstructs a session after restart', () => {
    const store = new SessionEventStore(':memory:');
    store.createSession({ id: 's1', projectPath: '/tmp/project', title: 'Fix login', mode: 'accept_edits' });
    store.append('s1', { type: 'session_status_changed', status: 'planning' });
    store.append('s1', { type: 'plan_updated', steps: [{ id: 'inspect', title: 'Inspect auth flow', status: 'active' }] });

    expect(store.listSessions()).toEqual([
      expect.objectContaining({ id: 's1', title: 'Fix login', mode: 'accept_edits' })
    ]);
    expect(store.loadEvents('s1')).toEqual([
      { type: 'session_status_changed', status: 'planning' },
      { type: 'plan_updated', steps: [{ id: 'inspect', title: 'Inspect auth flow', status: 'active' }] }
    ]);
    store.close();
  });
});
