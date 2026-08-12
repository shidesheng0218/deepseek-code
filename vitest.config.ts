import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Playwright specs have a different test runner and must only run via
    // `npm run test:e2e`; keeping them out prevents Vitest from importing
    // @playwright/test and reporting a misleading suite failure.
    exclude: ['**/node_modules/**', '**/dist/**', 'e2e/**', '**/e2e/**']
  }
})
