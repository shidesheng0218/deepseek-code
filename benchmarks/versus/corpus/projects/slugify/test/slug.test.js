import { test } from 'node:test';
import assert from 'node:assert/strict';
import { slugify } from '../src/slug.js';

test('基本转换', () => {
  assert.equal(slugify('Hello World'), 'hello-world');
});

test('去除首尾连字符与空白', () => {
  assert.equal(slugify('  --Hi--There--  '), 'hi-there');
});

test('连续空白与符号折叠为单个连字符', () => {
  assert.equal(slugify('a  b___c!!d'), 'a-b-c-d');
});

test('已是合法 slug 则保持不变', () => {
  assert.equal(slugify('deepseek-code'), 'deepseek-code');
});

test('空字符串', () => {
  assert.equal(slugify(''), '');
});
