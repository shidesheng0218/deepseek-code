import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTenantCache } from '../src/tenantCache.js';

function makeLoader() {
  const calls = [];
  const loader = async (tenantId, userId) => {
    calls.push(`${tenantId}:${userId}`);
    return { tenantId, userId, name: `${tenantId} 的 ${userId}` };
  };
  return { loader, calls };
}

test('不同租户的同 ID 用户不串数据', async () => {
  const { loader } = makeLoader();
  const cache = createTenantCache(loader);
  const a = await cache.get('tenant-a', 'u1');
  const b = await cache.get('tenant-b', 'u1');
  assert.equal(a.tenantId, 'tenant-a');
  assert.equal(b.tenantId, 'tenant-b');
});

test('同一租户同一用户命中缓存，只加载一次', async () => {
  const { loader, calls } = makeLoader();
  const cache = createTenantCache(loader);
  await cache.get('tenant-a', 'u1');
  await cache.get('tenant-a', 'u1');
  assert.deepEqual(calls, ['tenant-a:u1']);
});
