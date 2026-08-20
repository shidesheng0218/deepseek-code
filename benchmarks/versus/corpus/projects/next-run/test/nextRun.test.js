import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextRun } from '../src/nextRun.js';

test('当天时间未到则当天运行', () => {
  const from = new Date(2026, 7, 20, 5, 30);
  const next = nextRun(from, 6, 0);
  assert.equal(next.getDate(), 20);
  assert.equal(next.getHours(), 6);
});

test('当天时间已过则排到第二天', () => {
  const from = new Date(2026, 7, 20, 23, 50);
  const next = nextRun(from, 6, 0);
  assert.equal(next.getDate(), 21);
  assert.equal(next.getHours(), 6);
});

test('恰好等于运行时刻算作下一次（排到明天）', () => {
  const from = new Date(2026, 7, 20, 6, 0, 0, 0);
  const next = nextRun(from, 6, 0);
  assert.equal(next.getDate(), 21);
});
