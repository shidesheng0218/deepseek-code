import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addMoney, sumMoney } from '../src/money.js';

test('0.1 + 0.2 精确等于 0.3', () => {
  assert.equal(addMoney(0.1, 0.2), 0.3);
});

test('合计无浮点尾巴', () => {
  assert.equal(sumMoney([19.9, 5.05, 0.1, 0.2]), 25.25);
});

test('整数金额不受影响', () => {
  assert.equal(addMoney(10, 5), 15);
});
