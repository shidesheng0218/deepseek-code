import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupBy } from '../src/groupBy.js';

test('按选择器分组并保持组内顺序', () => {
  const items = [
    { type: 'fruit', name: 'apple' },
    { type: 'veg', name: 'carrot' },
    { type: 'fruit', name: 'banana' }
  ];
  assert.deepEqual(groupBy(items, (item) => item.type), {
    fruit: [{ type: 'fruit', name: 'apple' }, { type: 'fruit', name: 'banana' }],
    veg: [{ type: 'veg', name: 'carrot' }]
  });
});

test('组键按首次出现顺序排列', () => {
  const items = [{ k: 'b' }, { k: 'a' }, { k: 'b' }];
  assert.deepEqual(Object.keys(groupBy(items, (item) => item.k)), ['b', 'a']);
});

test('空数组返回空对象', () => {
  assert.deepEqual(groupBy([], (item) => item.k), {});
});

test('数字键按字符串归一', () => {
  const items = [{ score: 1 }, { score: 2 }, { score: 1 }];
  assert.deepEqual(groupBy(items, (item) => item.score), { 1: [{ score: 1 }, { score: 1 }], 2: [{ score: 2 }] });
});
