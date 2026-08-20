import { test } from 'node:test';
import assert from 'node:assert/strict';
import { naturalSort } from '../src/naturalSort.js';

test('数字段按数值排序', () => {
  assert.deepEqual(naturalSort(['file10', 'file2', 'file1']), ['file1', 'file2', 'file10']);
});

test('混合前缀按字典序再按数值', () => {
  assert.deepEqual(naturalSort(['b2', 'a10', 'a2', 'b1']), ['a2', 'a10', 'b1', 'b2']);
});

test('不修改入参', () => {
  const input = ['x10', 'x2'];
  naturalSort(input);
  assert.deepEqual(input, ['x10', 'x2']);
});
