import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createWindow } from '../src/window.js';

function clock(start = 1_000_000) {
  let current = start;
  return { now: () => current, advance: (ms) => { current += ms; } };
}

test('统计窗口内的事件数', () => {
  const clockA = clock();
  const win = createWindow(1000, clockA.now);
  win.record();
  win.record();
  assert.equal(win.count(), 2);
});

test('滑出窗口的事件不再计入', () => {
  const clockA = clock();
  const win = createWindow(1000, clockA.now);
  win.record();
  clockA.advance(500);
  win.record();
  assert.equal(win.count(), 2);
  clockA.advance(600);
  assert.equal(win.count(), 1);
  clockA.advance(500);
  assert.equal(win.count(), 0);
});
