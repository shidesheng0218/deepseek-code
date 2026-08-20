import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runAll } from '../src/pool.js';

function makeTasks(count, tracker, ms = 5) {
  return Array.from({ length: count }, (_, index) => async () => {
    tracker.running += 1;
    tracker.peak = Math.max(tracker.peak, tracker.running);
    await new Promise((resolve) => setTimeout(resolve, ms));
    tracker.running -= 1;
    return index;
  });
}

test('并发峰值不超过 limit', async () => {
  const tracker = { running: 0, peak: 0 };
  await runAll(makeTasks(20, tracker), 3);
  assert.ok(tracker.peak <= 3, `峰值 ${tracker.peak} 超过 3`);
});

test('结果顺序与输入一致', async () => {
  const tracker = { running: 0, peak: 0 };
  const results = await runAll(makeTasks(9, tracker), 2);
  assert.deepEqual(results, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
});
