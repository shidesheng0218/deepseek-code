import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions } from '../src/compare.js';

test('主版本优先', () => {
  assert.equal(compareVersions('2.0.0', '1.9.9'), 1);
  assert.equal(compareVersions('1.9.9', '2.0.0'), -1);
});

test('次版本与修订版本依次比较', () => {
  assert.equal(compareVersions('1.2.0', '1.10.0'), -1);
  assert.equal(compareVersions('1.2.10', '1.2.9'), 1);
  assert.equal(compareVersions('1.2.3', '1.2.3'), 0);
});

test('带 v 前缀与短版本归一', () => {
  assert.equal(compareVersions('v1.2', '1.2.0'), 0);
  assert.equal(compareVersions('1.2', '1.10'), -1);
});
