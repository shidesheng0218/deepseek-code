import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sanitizeFilename } from '../src/sanitize.js';

test('正反斜杠与冒号都替换', () => {
  assert.equal(sanitizeFilename('a/b\\c:d'), 'a-b-c-d');
});

test('星号问号引号尖括号竖线也非法', () => {
  assert.equal(sanitizeFilename('a*b?c"d<e>f|g'), 'a-b-c-d-e-f-g');
});

test('合法字符原样保留', () => {
  assert.equal(sanitizeFilename('报告 2026-08-20.md'), '报告 2026-08-20.md');
});
