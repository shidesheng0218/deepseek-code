import { test } from 'node:test';
import assert from 'node:assert/strict';
import { percentage } from '../src/percent.js';

test('正常计算并取整', () => {
  assert.equal(percentage(1, 4), 25);
  assert.equal(percentage(1, 3), 33);
});

test('总量为 0 返回 0 而不是 NaN', () => {
  assert.equal(percentage(0, 0), 0);
  assert.equal(percentage(5, 0), 0);
});
