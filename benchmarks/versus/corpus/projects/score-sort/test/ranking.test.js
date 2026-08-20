import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sortScoresDesc } from '../src/ranking.js';

test('按数值从高到低排序', () => {
  assert.deepEqual(sortScoresDesc([10, 9, 80, 100, 5]), [100, 80, 10, 9, 5]);
});

test('不修改调用方传入的数组', () => {
  const input = [3, 1, 2];
  sortScoresDesc(input);
  assert.deepEqual(input, [3, 1, 2]);
});

test('空数组与单元素', () => {
  assert.deepEqual(sortScoresDesc([]), []);
  assert.deepEqual(sortScoresDesc([7]), [7]);
});
