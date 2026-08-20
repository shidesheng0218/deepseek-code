import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createEmitter } from '../src/emitter.js';

test('off 精确移除指定监听器', () => {
  const emitter = createEmitter();
  const calls = [];
  const a = (p) => calls.push(`a${p}`);
  const b = (p) => calls.push(`b${p}`);
  emitter.on('tick', a);
  emitter.on('tick', b);
  emitter.off('tick', a);
  emitter.emit('tick', 1);
  assert.deepEqual(calls, ['b1']);
});

test('重复注册同一函数可全部触发', () => {
  const emitter = createEmitter();
  let count = 0;
  const fn = () => { count += 1; };
  emitter.on('x', fn);
  emitter.on('x', fn);
  emitter.emit('x');
  assert.equal(count, 2);
});
