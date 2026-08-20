import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseDuration } from '../src/parseDuration.js';

test('单单位解析', () => {
  assert.equal(parseDuration('90s'), 90_000);
  assert.equal(parseDuration('45m'), 45 * 60_000);
  assert.equal(parseDuration('2h'), 2 * 3_600_000);
  assert.equal(parseDuration('1d'), 86_400_000);
});

test('组合单位', () => {
  assert.equal(parseDuration('1h30m'), 5_400_000);
  assert.equal(parseDuration('1d12h'), 129_600_000);
});

test('非法输入抛错', () => {
  assert.throws(() => parseDuration(''), /invalid duration/);
  assert.throws(() => parseDuration('abc'), /invalid duration/);
  assert.throws(() => parseDuration('10x'), /invalid duration/);
});
