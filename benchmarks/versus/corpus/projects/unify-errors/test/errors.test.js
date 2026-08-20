import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requireToken } from '../src/auth.js';
import { requireKey } from '../src/store.js';

test('抛出的错误是 Error 实例且消息不变', () => {
  assert.throws(() => requireToken(''), (error) => error instanceof Error && error.message === 'token is required');
  assert.throws(() => requireToken('abc'), (error) => error instanceof Error && error.message === 'token is too short');
  assert.throws(() => requireKey(''), (error) => error instanceof Error && error.message === 'key is required');
});

test('错误带稳定 code 便于程序判断', () => {
  try {
    requireToken('');
    assert.fail('应当抛出');
  } catch (error) {
    assert.equal(error.code, 'AUTH_TOKEN_REQUIRED');
  }
});
