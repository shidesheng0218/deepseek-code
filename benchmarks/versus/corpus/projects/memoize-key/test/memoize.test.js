import { test } from 'node:test';
import assert from 'node:assert/strict';
import { memoize } from '../src/memoize.js';

test('键顺序不同的同值对象命中同一缓存', () => {
  let calls = 0;
  const fn = memoize((input) => { calls += 1; return input.a + input.b; });
  assert.equal(fn({ a: 1, b: 2 }), 3);
  assert.equal(fn({ b: 2, a: 1 }), 3);
  assert.equal(calls, 1);
});

test('不同参数仍然分别缓存', () => {
  let calls = 0;
  const fn = memoize((input) => { calls += 1; return input.a + input.b; });
  fn({ a: 1, b: 2 });
  fn({ a: 2, b: 2 });
  assert.equal(calls, 2);
});
