import { test } from 'node:test';
import assert from 'node:assert/strict';
import { maskIdNumber } from '../src/mask.js';

test('18 位证件号保留前 4 后 4', () => {
  assert.equal(maskIdNumber('110101199003077777'), '1101**********7777');
});

test('脱敏结果长度与原文一致', () => {
  const masked = maskIdNumber('110101199003077777');
  assert.equal(masked.length, 18);
  assert.ok(!masked.includes('1990'));
});

test('长度不足的原样返回', () => {
  assert.equal(maskIdNumber('12345678'), '12345678');
});
