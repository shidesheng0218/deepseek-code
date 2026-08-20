import { afterEach, describe, expect, test } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openProjection, type Projection } from '../../src/core/session-projection';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { while (cleanups.length) await cleanups.pop()?.(); });

async function openMemory(): Promise<Projection> {
  const projection = await openProjection(':memory:');
  cleanups.push(async () => projection.close());
  return projection;
}

function at(dayOffset: number, hour = 10): string {
  const base = new Date(2026, 7, 20, hour, 0, 0);
  base.setDate(base.getDate() + dayOffset);
  return base.toISOString();
}

describe('session projection（SQLite 物化视图）', () => {
  test('recordEvent 生成会话摘要：首条 turn_started 提供标题与项目路径', async () => {
    const projection = await openMemory();
    projection.recordEvent({ sessionID: 's1', sequence: 1, type: 'turn_started', payload: { prompt: '修复登录状态不同步的问题，这个缺陷已经严重影响到生产环境的用户体验，需要立即定位根因、给出修复方案并补充回归测试用例', projectPath: '/tmp/demo' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 2, type: 'assistant_text', payload: { text: '已定位' }, createdAt: at(0, 11) });

    const sessions = projection.listSessions();
    expect(sessions).toHaveLength(1);
    expect(sessions[0]?.sessionID).toBe('s1');
    expect(sessions[0]?.projectPath).toBe('/tmp/demo');
    expect(sessions[0]?.title.endsWith('…')).toBe(true);
    expect([...sessions[0]?.title ?? ''].length).toBe(57);
    expect(sessions[0]?.eventCount).toBe(2);
    expect(sessions[0]?.updatedAt).toBe(Date.parse(at(0, 11)));
  });

  test('usageStats 与 Rust 版统计语义一致（含时间窗口）', async () => {
    const projection = await openMemory();
    const now = new Date(2026, 7, 20, 12, 0, 0);
    projection.recordEvent({ sessionID: 's1', sequence: 1, type: 'turn_started', payload: { prompt: '修复登录问题' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 2, type: 'usage_recorded', payload: { inputTokens: 100, outputTokens: 50, cachedInputTokens: 10, model: 'deepseek-chat' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 3, type: 'turn_ended', payload: { status: 'completed' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 4, type: 'turn_started', payload: { prompt: '第二个问题' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 5, type: 'turn_started', payload: { prompt: '旧问题' }, createdAt: at(-40) });

    const all = projection.usageStats(undefined, now);
    expect(all.sessions).toBe(1);
    expect(all.messages).toBe(4);
    expect(all.totalTokens).toBe(150);
    expect(all.cachedTokens).toBe(10);
    expect(all.activeDays).toBe(2);
    expect(all.favoriteModel).toBe('deepseek-chat');
    expect(all.modelTokens[0]).toEqual({ model: 'deepseek-chat', tokens: 150 });
    expect(all.dailyActivity).toHaveLength(140);
    expect(all.dailyActivity.reduce((sum, count) => sum + count, 0)).toBe(5);
    expect(all.currentStreak).toBeGreaterThanOrEqual(1);
    expect(all.longestStreak).toBeGreaterThanOrEqual(1);
    expect(all.peakHour).toBe(10);

    const recent = projection.usageStats(30, now);
    expect(recent.messages).toBe(3);
    expect(recent.activeDays).toBe(1);
  });

  test('conversationAt 按事件水位重建对话（分叉点语义）', async () => {
    const projection = await openMemory();
    projection.recordEvent({ sessionID: 's1', sequence: 1, type: 'turn_started', payload: { prompt: '第一问' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 2, type: 'assistant_text', payload: { text: '第一答（' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 3, type: 'assistant_text', payload: { text: '续）' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 4, type: 'turn_ended', payload: { status: 'completed' }, createdAt: at(0) });
    projection.recordEvent({ sessionID: 's1', sequence: 5, type: 'turn_started', payload: { prompt: '第二问' }, createdAt: at(0, 11) });

    expect(projection.conversationAt('s1')).toEqual([
      { role: 'user', content: '第一问' },
      { role: 'assistant', content: '第一答（续）' },
      { role: 'user', content: '第二问' }
    ]);
    expect(projection.conversationAt('s1', 4)).toEqual([
      { role: 'user', content: '第一问' },
      { role: 'assistant', content: '第一答（续）' }
    ]);
  });

  test('rebuildFromJsonl 从真源日志整体重建投影', async () => {
    const root = await mkdtemp(join(tmpdir(), 'deepseek-projection-'));
    cleanups.push(async () => rm(root, { recursive: true, force: true }));
    const lines = [
      { type: 'turn_started', payload: { prompt: '重建测试', projectPath: '/tmp/rebuild' }, createdAt: at(0) },
      { type: 'usage_recorded', payload: { inputTokens: 10, outputTokens: 5, cachedInputTokens: 0, model: 'm' }, createdAt: at(0) },
      { type: 'turn_ended', payload: { status: 'completed' }, createdAt: at(0) }
    ];
    await writeFile(join(root, 'session-rebuild.jsonl'), lines.map((line) => JSON.stringify(line)).join('\n') + '\n');

    const projection = await openMemory();
    const rebuilt = await projection.rebuildFromJsonl(root);
    expect(rebuilt).toEqual({ sessions: 1, events: 3 });
    expect(projection.sessionEventCount('session-rebuild')).toBe(3);
    expect(projection.listSessions()[0]).toMatchObject({ title: '重建测试', projectPath: '/tmp/rebuild' });
    expect(projection.usageStats().totalTokens).toBe(15);
  });

  test('recordEvent 幂等覆盖同一 sequence（重放安全）', async () => {
    const projection = await openMemory();
    const event = { sessionID: 's1', sequence: 1, type: 'turn_started', payload: { prompt: '问' }, createdAt: at(0) };
    projection.recordEvent(event);
    projection.recordEvent(event);
    expect(projection.sessionEventCount('s1')).toBe(1);
  });
});
