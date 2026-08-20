import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createQueue } from '../src/queue.js';

test('先进先出', () => {
  const queue = createQueue();
  queue.enqueue('a');
  queue.enqueue('b');
  queue.enqueue('c');
  assert.equal(queue.dequeue(), 'a');
  assert.equal(queue.dequeue(), 'b');
  assert.equal(queue.size, 1);
});

test('空队列返回 undefined', () => {
  assert.equal(createQueue().dequeue(), undefined);
});
