import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createLru } from '../src/lru.js';

test('容量满时淘汰最久未使用的键', () => {
  const lru = createLru(2);
  lru.set('a', 1);
  lru.set('b', 2);
  lru.set('c', 3);
  assert.equal(lru.get('a'), undefined);
  assert.equal(lru.get('b'), 2);
  assert.equal(lru.get('c'), 3);
});

test('get 会刷新键的新鲜度', () => {
  const lru = createLru(2);
  lru.set('a', 1);
  lru.set('b', 2);
  lru.get('a');
  lru.set('c', 3);
  assert.equal(lru.get('a'), 1);
  assert.equal(lru.get('b'), undefined);
});

test('覆盖已存在的键会刷新其新鲜度且不增加占用', () => {
  const lru = createLru(2);
  lru.set('a', 1);
  lru.set('b', 2);
  lru.set('a', 9);
  lru.set('c', 3);
  assert.equal(lru.get('a'), 9);
  assert.equal(lru.get('b'), undefined);
});
