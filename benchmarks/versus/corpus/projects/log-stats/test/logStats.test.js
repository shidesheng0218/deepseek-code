import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summarizeLog } from '../src/logStats.js';

const SAMPLE = [
  '2026-08-20T10:00:01Z INFO 启动完成',
  '2026-08-20T10:00:02Z WARN 配置缺失，使用默认值',
  '2026-08-20T10:00:03Z ERROR 数据库连接失败',
  '2026-08-20T10:00:04Z ERROR 数据库连接失败',
  '2026-08-20T10:00:05Z ERROR 磁盘空间不足',
  '2026-08-20T10:00:06Z INFO 重试成功'
].join('\n');

test('统计各级别数量', () => {
  const summary = summarizeLog(SAMPLE);
  assert.deepEqual(summary.counts, { INFO: 2, WARN: 1, ERROR: 3 });
});

test('最高频错误消息', () => {
  assert.equal(summarizeLog(SAMPLE).topError, '数据库连接失败');
});

test('空日志', () => {
  assert.deepEqual(summarizeLog(''), { counts: { INFO: 0, WARN: 0, ERROR: 0 }, topError: null });
});
