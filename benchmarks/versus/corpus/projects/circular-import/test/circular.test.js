import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeAndShout } from '../src/a.js';
import { normalizeQuiet } from '../src/b.js';

test('组合函数行为不变', () => {
  assert.equal(normalizeAndShout('  Hello  '), 'HELLO!');
  assert.equal(normalizeQuiet('  World '), '[world]');
});
