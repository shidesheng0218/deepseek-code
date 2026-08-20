import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../src/idempotency.js';

function clock(start = 1_000_000) {
  let current = start;
  return { now: () => current, advance: (ms) => { current += ms; } };
}

test('TTL 内重复键被识别', () => {
  const clockA = clock();
  const store = createStore(60_000, clockA.now);
  store.add('k1');
  assert.equal(store.has('k1'), true);
});

test('超过 TTL 的键视为不存在且被清理', () => {
  const clockA = clock();
  const store = createStore(60_000, clockA.now);
  store.add('k1');
  clockA.advance(61_000);
  assert.equal(store.has('k1'), false);
  assert.equal(store.size, 0);
});
