import { test } from 'node:test';
import assert from 'node:assert/strict';
import { calculateTotal } from '../src/cart.js';

test('单件商品', () => {
  assert.equal(calculateTotal([{ price: 19.9, quantity: 1 }]), 19.9);
});

test('多件数量累计', () => {
  assert.equal(calculateTotal([{ price: 5, quantity: 3 }]), 15);
});

test('折扣按件数应用', () => {
  assert.equal(
    calculateTotal([
      { price: 10, quantity: 2, discount: 0.25 },
      { price: 1, quantity: 1 }
    ]),
    16
  );
});

test('空购物车为 0', () => {
  assert.equal(calculateTotal([]), 0);
});
