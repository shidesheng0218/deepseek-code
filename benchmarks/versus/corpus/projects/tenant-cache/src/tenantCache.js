/** 租户用户资料缓存：loader(tenantId, userId) 从存储加载。 */
export function createTenantCache(loader) {
  const cache = new Map();
  return {
    async get(tenantId, userId) {
      const key = userId;
      if (!cache.has(key)) cache.set(key, await loader(tenantId, userId));
      return cache.get(key);
    },
    size() { return cache.size; }
  };
}
