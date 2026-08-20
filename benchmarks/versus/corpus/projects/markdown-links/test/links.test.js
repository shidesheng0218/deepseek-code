import { test } from 'node:test';
import assert from 'node:assert/strict';
import { extractLinks } from '../src/links.js';

test('普通链接', () => {
  assert.deepEqual(extractLinks('见 [文档](https://example.com/docs) 了解'), [
    { text: '文档', url: 'https://example.com/docs' }
  ]);
});

test('URL 内含成对括号不截断', () => {
  assert.deepEqual(extractLinks('[Foo](/wiki/Foo_(bar))'), [
    { text: 'Foo', url: '/wiki/Foo_(bar)' }
  ]);
});

test('多个链接与非链接括号', () => {
  const links = extractLinks('（无关）[a](/a) 文本 [b](/b_(x)) 结束');
  assert.deepEqual(links.map((link) => link.url), ['/a', '/b_(x)']);
});
