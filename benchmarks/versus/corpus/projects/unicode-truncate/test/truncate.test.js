import { test } from 'node:test';
import assert from 'node:assert/strict';
import { truncate } from '../src/truncate.js';

test('emoji 不被切成半个代理对', () => {
  assert.equal(truncate('a🚀b', 2), 'a🚀…');
});

test('普通 ASCII 截断', () => {
  assert.equal(truncate('hello world', 5), 'hello…');
});

test('不超过长度原样返回', () => {
  assert.equal(truncate('短', 4), '短');
  assert.equal(truncate('a🚀', 2), 'a🚀');
});

test('截断结果不含孤立代理对', () => {
  const out = truncate('🎉🎉🎉🎉', 2);
  for (const ch of out) {
    const code = ch.codePointAt(0);
    assert.ok(!(code >= 0xd800 && code <= 0xdfff), `存在孤立代理对: ${code.toString(16)}`);
  }
});
