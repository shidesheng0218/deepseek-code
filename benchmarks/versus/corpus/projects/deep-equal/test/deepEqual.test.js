import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deepEqual } from '../src/deepEqual.js';

test('键顺序不同但内容相同应判相等', () => {
  assert.equal(deepEqual({ a: 1, b: { c: 2, d: 3 } }, { b: { d: 3, c: 2 }, a: 1 }), true);
});

test('数组顺序敏感', () => {
  assert.equal(deepEqual([1, 2], [2, 1]), false);
});

test('基本类型与不等对象', () => {
  assert.equal(deepEqual(1, 1), true);
  assert.equal(deepEqual({ a: 1 }, { a: 2 }), false);
  assert.equal(deepEqual(null, null), true);
});
