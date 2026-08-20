import { test } from 'node:test';
import assert from 'node:assert/strict';
import { topWords } from '../src/topWords.js';

test('按词频降序取前 k 个', () => {
  assert.deepEqual(topWords('a b a c b a', 2), [['a', 3], ['b', 2]]);
});

test('大小写与标点归一', () => {
  assert.deepEqual(topWords('Hello, hello! HELLO; world.', 2), [['hello', 3], ['world', 1]]);
});

test('同频按字母序，空文本返回空数组', () => {
  assert.deepEqual(topWords('b a', 5), [['a', 1], ['b', 1]]);
  assert.deepEqual(topWords('', 3), []);
});
