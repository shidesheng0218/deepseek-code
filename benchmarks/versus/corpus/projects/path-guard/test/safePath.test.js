import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sep } from 'node:path';
import { resolveUnderRoot } from '../src/safePath.js';

test('正常子路径解析通过', () => {
  const resolved = resolveUnderRoot('/srv/data', 'sub/file.txt');
  assert.equal(resolved, `/srv/data${sep}sub${sep}file.txt`);
});

test('根目录本身允许', () => {
  assert.equal(resolveUnderRoot('/srv/data', '.'), '/srv/data');
});

test('兄弟目录前缀混淆必须拦截', () => {
  assert.throws(() => resolveUnderRoot('/srv/data', '../data-secret/key.pem'), /escapes root/);
});

test('显式向上逃逸必须拦截', () => {
  assert.throws(() => resolveUnderRoot('/srv/data', '../../etc/passwd'), /escapes root/);
});

test('路径内部含 .. 但最终落在根内是允许的', () => {
  const resolved = resolveUnderRoot('/srv/data', 'a/b/../c.txt');
  assert.equal(resolved, `/srv/data${sep}a${sep}c.txt`);
});
