import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEmail } from '../src/validate.js';

test('正常邮箱通过', () => {
  assert.equal(isEmail('user@example.com'), true);
});

test('明显非法输入拒绝', () => {
  assert.equal(isEmail('not-an-email'), false);
});

test('恶意输入在毫秒级返回', () => {
  const evil = `${'a'.repeat(30)}!`;
  const started = Date.now();
  assert.equal(isEmail(evil), false);
  assert.ok(Date.now() - started < 100, '校验耗时过长');
});
