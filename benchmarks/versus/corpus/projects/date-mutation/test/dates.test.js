import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addDays, startOfDay } from '../src/dates.js';

test('startOfDay 返回当天零点', () => {
  const result = startOfDay(new Date('2026-08-20T15:30:45'));
  assert.equal(result.getHours(), 0);
  assert.equal(result.getMinutes(), 0);
  assert.equal(result.getSeconds(), 0);
});

test('startOfDay 不修改传入的 Date', () => {
  const input = new Date('2026-08-20T15:30:45');
  startOfDay(input);
  assert.equal(input.getHours(), 15);
});

test('addDays 正确跨月且同样不修改入参', () => {
  const input = new Date('2026-08-31T10:00:00');
  const result = addDays(input, 1);
  assert.equal(result.getMonth(), 8);
  assert.equal(result.getDate(), 1);
  assert.equal(input.getDate(), 31);
});
