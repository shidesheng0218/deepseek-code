/** 令牌桶限流器：容量 capacity，每秒补充 refillPerSecond 个令牌。now 可注入便于测试。 */
export function createRateLimiter({ capacity, refillPerSecond, now = () => Date.now() }) {
  let tokens = capacity;
  let last = now();
  return {
    allow() {
      const current = now();
      const elapsed = (current - last) / 1000;
      last = current;
      tokens = Math.min(capacity, tokens + elapsed * refillPerSecond);
      if (tokens > 1) {
        tokens -= 1;
        return true;
      }
      return false;
    }
  };
}
