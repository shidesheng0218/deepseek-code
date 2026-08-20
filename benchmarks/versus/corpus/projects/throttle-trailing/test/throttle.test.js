import { test } from 'node:test';
import assert from 'node:assert/strict';
import { throttle } from '../src/throttle.js';

test('窗口内只执行一次，窗口结束后尾随调用带最新参数执行', () => {
  let current = 0;
  const timers = [];
  const calls = [];
  const fn = (value) => calls.push({ value, at: current });
  const throttled = throttle(fn, 50, {
    now: () => current,
    schedule: (cb, ms) => timers.push({ cb, runAt: current + ms })
  });
  throttled(1);
  current = 10;
  throttled(2);
  current = 20;
  throttled(3);
  assert.deepEqual(calls, [{ value: 1, at: 0 }]);
  assert.equal(timers.length, 1);
  current = timers[0].runAt;
  timers[0].cb();
  assert.deepEqual(calls, [{ value: 1, at: 0 }, { value: 3, at: 50 }]);
});
