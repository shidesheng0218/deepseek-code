export function loadConfig(overrides = {}) {
  return { retryCount: 3, timeoutMs: 5000, ...overrides };
}
