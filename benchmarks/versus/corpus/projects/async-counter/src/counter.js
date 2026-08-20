/** 访问计数器。 */
export function createCounter() {
  let count = 0;
  return {
    async increment() {
      const current = count;
      await new Promise((resolve) => setImmediate(resolve));
      count = current + 1;
    },
    get value() { return count; }
  };
}
