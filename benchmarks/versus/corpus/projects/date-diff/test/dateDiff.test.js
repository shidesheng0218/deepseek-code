import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dayDiff } from '../src/dateDiff.js';

test('相邻日期恒为 1，与时刻无关', () => {
  assert.equal(dayDiff('2026-03-01T23:00:00', '2026-03-02T01:00:00'), 1);
});

test('跨月边界', () => {
  assert.equal(dayDiff('2026-01-31', '2026-02-01'), 1);
});

test('跨年与整年', () => {
  assert.equal(dayDiff('2025-12-31', '2026-01-01'), 1);
  assert.equal(dayDiff('2026-01-01', '2027-01-01'), 365);
});
