import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Playwright specs have a different test runner and must only run via
    // `npm run test:e2e`; keeping them out prevents Vitest from importing
    // @playwright/test and reporting a misleading suite failure.
    // benchmarks/versus/corpus 是"故意埋 bug"的对照夹具，不是本仓库的测试；
    // 它们必须留在 lint 的 ignore 与 vitest 的 exclude 里，否则 `vitest run`
    // 会混进 60 个假失败，把真正的回归信号淹掉。
    exclude: ['**/node_modules/**', '**/dist/**', 'e2e/**', '**/e2e/**', '**/benchmarks/versus/corpus/**']
  }
})
