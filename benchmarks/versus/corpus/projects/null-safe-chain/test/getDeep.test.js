import { test } from 'node:test';
import assert from 'node:assert/strict';
import { getDeep } from '../src/getDeep.js';

test('完整路径取值', () => {
  assert.equal(getDeep({ a: { b: { c: 42 } } }, 'a.b.c'), 42);
});

test('中间段为 null 返回 undefined 而不抛错', () => {
  assert.equal(getDeep({ a: null }, 'a.b.c'), undefined);
});

test('首段即缺失', () => {
  assert.equal(getDeep({}, 'x.y'), undefined);
});
