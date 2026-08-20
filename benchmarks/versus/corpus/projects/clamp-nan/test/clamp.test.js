import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clamp } from '../src/clamp.js';

test('常规钳制', () => {
  assert.equal(clamp(11, 0, 10), 10);
  assert.equal(clamp(-1, 0, 10), 0);
  assert.equal(clamp(5, 0, 10), 5);
});

test('NaN 按最小值处理', () => {
  assert.equal(clamp(Number('abc'), 0, 10), 0);
});

test('倒置区间自动互换', () => {
  assert.equal(clamp(5, 10, 0), 5);
  assert.equal(clamp(11, 10, 0), 10);
});
