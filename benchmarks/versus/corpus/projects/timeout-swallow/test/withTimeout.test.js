import { test } from 'node:test';
import assert from 'node:assert/strict';
import { withTimeout } from '../src/withTimeout.js';

test('超时抛出带名称的错误', async () => {
  const slow = new Promise((resolve) => setTimeout(resolve, 200, 'late'));
  await assert.rejects(() => withTimeout(slow, 10), /TimeoutError/);
});

test('按时完成返回原值', async () => {
  assert.equal(await withTimeout(Promise.resolve('fast'), 100), 'fast');
});

test('内部拒绝不被吞掉', async () => {
  await assert.rejects(() => withTimeout(Promise.reject(new Error('inner boom')), 100), /inner boom/);
});
