import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  fullyParallel: false,
  reporter: [['list'], ['json', { outputFile: 'e2e/artifacts/playwright-report.json' }]],
  use: {
    baseURL: 'http://127.0.0.1:4317',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure'
  },
  webServer: {
    command: 'node fixture-web/server.mjs',
    url: 'http://127.0.0.1:4317',
    reuseExistingServer: false,
    timeout: 20_000
  }
})
