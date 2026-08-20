import { test } from 'node:test';
import assert from 'node:assert/strict';
import { withRetry } from '../src/retry.js';

function recorder() {
  const calls = [];
  return { calls, sleep: async (ms) => { calls.push(ms); } };
}

test('前两次失败后第三次成功：返回结果且退避间隔指数增长', async () => {
  const { calls, sleep } = recorder();
  let attempts = 0;
  const fn = async () => {
    attempts += 1;
    if (attempts < 3) throw new Error(`flaky ${attempts}`);
    return 'ok';
  };
  const value = await withRetry(fn, { retries: 3, baseDelayMs: 50, sleep });
  assert.equal(value, 'ok');
  assert.equal(attempts, 3);
  assert.deepEqual(calls, [50, 100]);
});

test('重试耗尽后抛出最后一次错误', async () => {
  const { calls, sleep } = recorder();
  let attempts = 0;
  const fn = async () => { attempts += 1; throw new Error(`boom ${attempts}`); };
  await assert.rejects(() => withRetry(fn, { retries: 2, baseDelayMs: 50, sleep }), /boom 3/);
  assert.equal(attempts, 3);
  assert.deepEqual(calls, [50, 100]);
});

test('第一次就成功则不 sleep', async () => {
  const { calls, sleep } = recorder();
  const value = await withRetry(async () => 'fast', { retries: 3, baseDelayMs: 50, sleep });
  assert.equal(value, 'fast');
  assert.deepEqual(calls, []);
});
