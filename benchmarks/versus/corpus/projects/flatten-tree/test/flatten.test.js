import { test } from 'node:test';
import assert from 'node:assert/strict';
import { flattenTree } from '../src/flatten.js';

const tree = {
  id: 'root',
  children: [
    { id: 'a', children: [{ id: 'a1', children: [] }] },
    { id: 'b', children: [] }
  ]
};

test('DFS 先序展开', () => {
  assert.deepEqual(flattenTree(tree).map((node) => node.id), ['root', 'a', 'a1', 'b']);
});

test('无 children 字段与空数组都按叶子处理', () => {
  assert.deepEqual(flattenTree({ id: 'solo' }).map((node) => node.id), ['solo']);
});

test('返回的节点不含 children 字段', () => {
  assert.ok(flattenTree(tree).every((node) => !('children' in node)));
});
