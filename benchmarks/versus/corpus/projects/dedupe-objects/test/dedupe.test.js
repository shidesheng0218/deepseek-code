import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dedupeById } from '../src/dedupe.js';

test('同 id 只保留首次出现的记录', () => {
  const users = [
    { id: 1, name: 'ada' },
    { id: 2, name: 'grace' },
    { id: 1, name: 'ada-改名后' }
  ];
  assert.deepEqual(dedupeById(users), [
    { id: 1, name: 'ada' },
    { id: 2, name: 'grace' }
  ]);
});

test('保持原有相对顺序', () => {
  const users = [{ id: 3 }, { id: 1 }, { id: 2 }, { id: 1 }];
  assert.deepEqual(dedupeById(users).map((user) => user.id), [3, 1, 2]);
});

test('空数组', () => {
  assert.deepEqual(dedupeById([]), []);
});
