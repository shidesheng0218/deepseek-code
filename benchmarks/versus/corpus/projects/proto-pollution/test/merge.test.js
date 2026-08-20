import { test } from 'node:test';
import assert from 'node:assert/strict';
import { merge } from '../src/merge.js';

test('正常键合并', () => {
  assert.deepEqual(merge({ a: 1 }, { b: 2 }), { a: 1, b: 2 });
});

test('危险键被跳过且不污染原型', () => {
  const malicious = JSON.parse('{"__proto__": {"polluted": true}, "constructor": {"x": 1}, "safe": 1}');
  const result = merge({}, malicious);
  assert.equal(result.safe, 1);
  assert.equal(Object.prototype.polluted, undefined);
  assert.equal(result.polluted, undefined);
  assert.equal(Object.keys(result).includes('__proto__'), false);
});
