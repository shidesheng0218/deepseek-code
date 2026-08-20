import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildQuery } from '../src/query.js';

test('标量值正确编码', () => {
  assert.equal(buildQuery({ q: 'a b', page: 2 }), 'q=a%20b&page=2');
});

test('数组值展开为重复键', () => {
  assert.equal(buildQuery({ tag: ['x', 'y'] }), 'tag=x&tag=y');
});

test('键也需要编码，空对象为 空串', () => {
  assert.equal(buildQuery({ 'a b': 'c' }), 'a%20b=c');
  assert.equal(buildQuery({}), '');
});
