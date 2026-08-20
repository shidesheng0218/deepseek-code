import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addTag } from '../src/userTags.js';

test('副本包含新标签', () => {
  const user = { name: 'ada', tags: ['admin'] };
  const copy = addTag(user, 'editor');
  assert.deepEqual(copy.tags, ['admin', 'editor']);
});

test('原对象不被污染', () => {
  const user = { name: 'ada', tags: ['admin'] };
  addTag(user, 'editor');
  assert.deepEqual(user.tags, ['admin']);
});

test('其他字段保持共享语义不变', () => {
  const user = { name: 'ada', tags: [] };
  const copy = addTag(user, 'x');
  assert.equal(copy.name, 'ada');
});
