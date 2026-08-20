import { test } from 'node:test';
import assert from 'node:assert/strict';
import { paginate } from '../src/paginate.js';

const data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

test('第一页返回完整一页', () => {
  assert.deepEqual(paginate(data, 1, 3).items, [1, 2, 3]);
});

test('中间页不丢边界元素', () => {
  assert.deepEqual(paginate(data, 2, 3).items, [4, 5, 6]);
  assert.deepEqual(paginate(data, 3, 3).items, [7, 8, 9]);
});

test('最后一页返回剩余部分', () => {
  const result = paginate(data, 4, 3);
  assert.deepEqual(result.items, [10]);
  assert.equal(result.total, 10);
});

test('超出范围返回空页', () => {
  assert.deepEqual(paginate(data, 5, 3).items, []);
});
