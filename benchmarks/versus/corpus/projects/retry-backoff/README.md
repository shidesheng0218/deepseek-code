# withRetry 语料项目

实现 `src/retry.js` 并导出 `withRetry(fn, { retries, baseDelayMs, sleep })`：
失败时按指数退避重试，完整行为规格见 `test/retry.test.js`。
