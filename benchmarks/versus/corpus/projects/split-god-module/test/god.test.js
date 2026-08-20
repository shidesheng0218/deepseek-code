import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatBool, formatNumber, parseBool, parseNumber } from '../src/god.js';

test('解析与格式化行为不变', () => {
  assert.equal(parseBool('yes'), true);
  assert.equal(parseNumber('42'), 42);
  assert.equal(formatBool(true), '是');
  assert.equal(typeof formatNumber(1234), 'string');
});
