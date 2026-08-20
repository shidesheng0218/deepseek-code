/** 节流：每个窗口最多执行一次。now/schedule 可注入便于测试。 */
export function throttle(fn, waitMs, { now = () => Date.now(), schedule = (cb, ms) => setTimeout(cb, ms) } = {}) {
  let last = -Infinity;
  return (...args) => {
    const current = now();
    if (current - last >= waitMs) {
      last = current;
      fn(...args);
    }
  };
}
