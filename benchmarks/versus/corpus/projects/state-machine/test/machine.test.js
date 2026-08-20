import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMachine } from '../src/machine.js';

test('合法迁移链 pending→active→resolved→archived', () => {
  const machine = createMachine();
  machine.transition('active');
  machine.transition('resolved');
  machine.transition('archived');
  assert.equal(machine.state, 'archived');
});

test('跳级迁移被拒绝', () => {
  const machine = createMachine();
  assert.throws(() => machine.transition('resolved'), /invalid transition/);
  assert.throws(() => machine.transition('archived'), /invalid transition/);
  assert.equal(machine.state, 'pending');
});

test('resolved 不能回到 active', () => {
  const machine = createMachine();
  machine.transition('active');
  machine.transition('resolved');
  assert.throws(() => machine.transition('active'), /invalid transition/);
});
