import { test } from 'node:test';
import assert from 'node:assert/strict';
import { userEndpoint } from '../src/userService.js';
import { orderEndpoint } from '../src/orderService.js';
import { healthEndpoint } from '../src/health.js';

test('各端点拼接正确', () => {
  assert.equal(userEndpoint('u1'), 'https://api.internal.example/users/u1');
  assert.equal(orderEndpoint('o9'), 'https://api.internal.example/orders/o9');
  assert.equal(healthEndpoint(), 'https://api.internal.example/healthz');
});
