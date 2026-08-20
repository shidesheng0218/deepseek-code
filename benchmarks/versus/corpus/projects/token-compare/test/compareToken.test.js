import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenEqual } from '../src/compareToken.js';

test('完全相同才通过', () => {
  assert.equal(tokenEqual('abc12345', 'abc12345'), true);
});

test('前缀匹配不能通过', () => {
  assert.equal(tokenEqual('abc', 'abc12345'), false);
});

test('等长但不同不能通过', () => {
  assert.equal(tokenEqual('abc12346', 'abc12345'), false);
});

test('空输入安全', () => {
  assert.equal(tokenEqual('', 'x'), false);
});
