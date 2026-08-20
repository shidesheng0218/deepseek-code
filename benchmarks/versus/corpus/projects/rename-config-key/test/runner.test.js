import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runJob } from '../src/runner.js';

test('默认重试 3 次后抛出最后的错误', async () => {
  let attempts = 0;
  await assert.rejects(() => runJob(async () => { attempts += 1; throw new Error(`boom${attempts}`); }), /boom3/);
  assert.equal(attempts, 3);
});

test('可通过覆盖配置调整次数', async () => {
  let attempts = 0;
  await assert.rejects(() => runJob(async () => { attempts += 1; throw new Error('x'); }, { maxRetries: 1 }), /x/);
  assert.equal(attempts, 1);
});
