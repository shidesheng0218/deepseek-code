import { test } from 'node:test';
import assert from 'node:assert/strict';
import { windowed } from '../src/windowed.js';

test('默认步长为 1 的滑动窗口', () => {
  assert.deepEqual(windowed([1, 2, 3, 4], 3), [[1, 2, 3], [2, 3, 4]]);
});

test('指定步长', () => {
  assert.deepEqual(windowed([1, 2, 3, 4, 5], 2, 2), [[1, 2], [3, 4]]);
});

test('窗口大于数组与边界', () => {
  assert.deepEqual(windowed([1, 2], 5), []);
  assert.deepEqual(windowed([1, 2], 2), [[1, 2]]);
});
