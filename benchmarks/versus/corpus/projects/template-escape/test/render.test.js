import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../src/render.js';

test('双花括号插值并 HTML 转义', () => {
  assert.equal(render('你好 {{name}}', { name: '<b>世界</b>' }), '你好 &lt;b&gt;世界&lt;/b&gt;');
});

test('三花括号原样输出', () => {
  assert.equal(render('{{{html}}}', { html: '<b>加粗</b>' }), '<b>加粗</b>');
});

test('缺失变量渲染为空串，& 与引号也转义', () => {
  assert.equal(render('[{{missing}}]', {}), '[]');
  assert.equal(render('{{x}}', { x: 'a&b"c' }), 'a&amp;b&quot;c');
});
