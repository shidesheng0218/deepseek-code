import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderComment } from '../src/render.js';

test('脚本与标签被转义', () => {
  const out = renderComment('<img src=x onerror=alert(1)>');
  assert.ok(!out.includes('<img'));
  assert.ok(out.includes('&lt;img'));
});

test('五种字符全部转义', () => {
  const out = renderComment(`&<>"'`);
  assert.ok(out.includes('&amp;'));
  assert.ok(out.includes('&lt;'));
  assert.ok(out.includes('&gt;'));
  assert.ok(out.includes('&quot;'));
  assert.ok(out.includes('&#39;'));
});

test('普通文本不受影响', () => {
  assert.equal(renderComment('你好 世界'), '<div class="comment">你好 世界</div>');
});
