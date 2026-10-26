import { defineConfig } from '@playwright/test'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  fullyParallel: false,
  reporter: [['list'], ['json', { outputFile: fileURLToPath(new URL('./artifacts/playwright-report.json', import.meta.url)) }]],
  use: {
    baseURL: 'http://127.0.0.1:4317',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure'
  },
  webServer: {
    command: `node ${JSON.stringify(fileURLToPath(new URL('./fixture-web/server.mjs', import.meta.url)))}`,
    url: 'http://127.0.0.1:4317',
    reuseExistingServer: false,
    timeout: 20_000
  }
})
