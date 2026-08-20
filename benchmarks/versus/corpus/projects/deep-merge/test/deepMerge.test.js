import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deepMerge } from '../src/deepMerge.js';

test('嵌套对象递归合并', () => {
  assert.deepEqual(
    deepMerge({ a: { x: 1, y: 2 } }, { a: { y: 3, z: 4 } }),
    { a: { x: 1, y: 3, z: 4 } }
  );
});

test('数组整体替换而不是拼接', () => {
  assert.deepEqual(deepMerge({ list: [1, 2] }, { list: [3] }), { list: [3] });
});

test('不修改任何入参', () => {
  const target = { a: { x: 1 } };
  const source = { a: { y: 2 } };
  deepMerge(target, source);
  assert.deepEqual(target, { a: { x: 1 } });
  assert.deepEqual(source, { a: { y: 2 } });
});
