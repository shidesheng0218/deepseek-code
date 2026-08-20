import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCounter } from '../src/counter.js';

test('10 次并发递增全部生效', async () => {
  const counter = createCounter();
  await Promise.all(Array.from({ length: 10 }, () => counter.increment()));
  assert.equal(counter.value, 10);
});
