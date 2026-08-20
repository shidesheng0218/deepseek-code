/** 幂等键存储：TTL 内重复键返回已存在。now 可注入便于测试。 */
export function createStore(ttlMs, now = () => Date.now()) {
  const seen = new Map();
  return {
    has(key) {
      return seen.has(key);
    },
    add(key) {
      seen.set(key, now());
    },
    get size() { return seen.size; }
  };
}
