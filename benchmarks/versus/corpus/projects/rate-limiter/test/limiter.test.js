import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRateLimiter } from '../src/limiter.js';

function fakeClock(start = 1_000_000) {
  let current = start;
  return { now: () => current, advance: (ms) => { current += ms; } };
}

test('容量为 2 时突发两个请求都放行', () => {
  const clock = fakeClock();
  const limiter = createRateLimiter({ capacity: 2, refillPerSecond: 1, now: clock.now });
  assert.equal(limiter.allow(), true);
  assert.equal(limiter.allow(), true);
});

test('令牌耗尽后拒绝，补充后恢复', () => {
  const clock = fakeClock();
  const limiter = createRateLimiter({ capacity: 2, refillPerSecond: 1, now: clock.now });
  limiter.allow();
  limiter.allow();
  assert.equal(limiter.allow(), false);
  clock.advance(1000);
  assert.equal(limiter.allow(), true);
});

test('令牌累计不超过容量', () => {
  const clock = fakeClock();
  const limiter = createRateLimiter({ capacity: 1, refillPerSecond: 10, now: clock.now });
  clock.advance(60_000);
  assert.equal(limiter.allow(), true);
  assert.equal(limiter.allow(), false);
});
