import { describe, expect, it } from 'vitest';
import { canTransition, resolveDependencies, selectRunnable, selectDependencyResolved, type TaskTicket } from '../src/core/task-queue';

function ticket(id: string, state: TaskTicket['state'], overrides: Partial<TaskTicket> = {}): TaskTicket {
  return {
    ticketID: id, sessionID: id, prompt: 'x', projectPath: '/tmp', state, priority: 0,
    createdAt: 'now', updatedAt: 'now', ...overrides
  };
}

describe('canTransition', () => {
  it('allows queued -> running', () => {
    expect(canTransition('queued', 'running')).toBe(true);
  });

  it('rejects transitions out of terminal states (done/failed never resume)', () => {
    expect(canTransition('done', 'running')).toBe(false);
    expect(canTransition('failed', 'queued')).toBe(false);
  });

  it('allows running -> waiting_approval/waiting_ci (the two suspend points documented in the design)', () => {
    expect(canTransition('running', 'waiting_approval')).toBe(true);
    expect(canTransition('running', 'waiting_ci')).toBe(true);
  });

  it('rejects a direct queued -> done jump (must pass through running)', () => {
    expect(canTransition('queued', 'done')).toBe(false);
  });
});

describe('resolveDependencies', () => {
  it('is ready when there are no dependencies', () => {
    const t = ticket('a', 'queued');
    expect(resolveDependencies(t, { list: () => [t] })).toEqual({ ready: true });
  });

  it('is ready once every dependency reaches done', () => {
    const dep = ticket('a', 'done');
    const t = ticket('b', 'waiting_dependency', { blockedBy: ['a'] });
    expect(resolveDependencies(t, { list: () => [dep, t] })).toEqual({ ready: true });
  });

  it('is not ready while a dependency is still running', () => {
    const dep = ticket('a', 'running');
    const t = ticket('b', 'waiting_dependency', { blockedBy: ['a'] });
    const result = resolveDependencies(t, { list: () => [dep, t] });
    expect(result.ready).toBe(false);
  });

  it('reports a failed dependency as permanently blocking, not "still waiting"', () => {
    const dep = ticket('a', 'failed');
    const t = ticket('b', 'waiting_dependency', { blockedBy: ['a'] });
    const result = resolveDependencies(t, { list: () => [dep, t] });
    expect(result.ready).toBe(false);
    expect(result.blockedReason).toMatch(/已失败/);
  });

  it('reports a missing dependency ticket distinctly from a not-yet-done one', () => {
    const t = ticket('b', 'waiting_dependency', { blockedBy: ['nonexistent'] });
    const result = resolveDependencies(t, { list: () => [t] });
    expect(result.ready).toBe(false);
    expect(result.blockedReason).toMatch(/不存在/);
  });
});

describe('selectRunnable', () => {
  it('orders queued tickets by priority, highest first', () => {
    const low = ticket('low', 'queued', { priority: 1 });
    const high = ticket('high', 'queued', { priority: 5 });
    expect(selectRunnable([low, high]).map((t) => t.ticketID)).toEqual(['high', 'low']);
  });

  it('excludes tickets that are not in the queued state', () => {
    const running = ticket('r', 'running');
    const done = ticket('d', 'done');
    expect(selectRunnable([running, done])).toEqual([]);
  });
});

describe('selectDependencyResolved', () => {
  it('surfaces a waiting_dependency ticket once its dependency is done', () => {
    const dep = ticket('a', 'done');
    const waiting = ticket('b', 'waiting_dependency', { blockedBy: ['a'] });
    expect(selectDependencyResolved([dep, waiting]).map((t) => t.ticketID)).toEqual(['b']);
  });

  it('does not surface a waiting_dependency ticket whose dependency has not finished', () => {
    const dep = ticket('a', 'running');
    const waiting = ticket('b', 'waiting_dependency', { blockedBy: ['a'] });
    expect(selectDependencyResolved([dep, waiting])).toEqual([]);
  });
});
