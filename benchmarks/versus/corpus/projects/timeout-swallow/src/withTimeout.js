/** 给 Promise 加超时：超时后以 undefined 结算。 */
export function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((resolve) => setTimeout(() => resolve(undefined), ms))
  ]);
}
