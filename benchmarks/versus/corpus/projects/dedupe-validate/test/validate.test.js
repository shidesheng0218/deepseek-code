import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerUser } from '../src/register.js';
import { updateProfile } from '../src/profile.js';

test('注册合法用户并去除姓名首尾空白', () => {
  assert.deepEqual(registerUser({ name: '  Ada  ', age: 36 }), { name: 'Ada', age: 36 });
});

test('注册拒绝空姓名', () => {
  assert.throws(() => registerUser({ name: '   ', age: 30 }), /name is required/);
});

test('注册拒绝超长姓名', () => {
  assert.throws(() => registerUser({ name: 'x'.repeat(41), age: 30 }), /name is too long/);
});

test('资料更新拒绝非法年龄', () => {
  assert.throws(() => updateProfile({ name: 'Ada', age: 36 }, { age: 200 }), /age out of range/);
});

test('资料更新合并补丁', () => {
  assert.deepEqual(updateProfile({ name: 'Ada', age: 36 }, { age: 37 }), { name: 'Ada', age: 37 });
});
