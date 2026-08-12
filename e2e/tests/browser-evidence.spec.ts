import { expect, test } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'

test('captures deterministic browser evidence for a local web repair task', async ({ page }) => {
  const consoleErrors: string[] = []
  const networkFailures: string[] = []
  page.on('console', (message) => {
    if (message.type() === 'error') consoleErrors.push(message.text())
  })
  page.on('response', (response) => {
    if (response.status() >= 400) networkFailures.push(`${response.status()} ${response.url()}`)
  })

  await page.goto('/')
  await page.getByRole('button', { name: 'Load status' }).click()
  await expect(page.getByRole('status')).toHaveText('Service ready')
  await page.screenshot({ path: 'e2e/artifacts/fixture-success.png', fullPage: true })

  await page.getByRole('button', { name: 'Trigger failing request' }).click()
  await expect.poll(() => consoleErrors.length).toBeGreaterThan(0)
  await expect.poll(() => networkFailures.length).toBeGreaterThan(0)
  await page.screenshot({ path: 'e2e/artifacts/fixture-failure.png', fullPage: true })

  await mkdir('e2e/artifacts', { recursive: true })
  const accessibilityTree = await page.locator('button, [role="status"]').evaluateAll((elements) => elements.map((element) => `${element.tagName.toLowerCase()}: ${(element.textContent ?? '').trim()}`).join('\n'))
  await writeFile('e2e/artifacts/browser-evidence.json', JSON.stringify({
    url: page.url(),
    title: await page.title(),
    domSummary: await page.locator('body').innerText(),
    accessibilityTree,
    consoleErrors,
    networkFailures,
    screenshotPath: 'e2e/artifacts/fixture-failure.png',
    actions: [
      { tool: 'browser.click', selector: '#load-status', snapshotVersion: 1, succeeded: true },
      { tool: 'browser.click', selector: '#trigger-failure', snapshotVersion: 2, succeeded: true }
    ],
    passedAssertions: ['load-status'],
    failedAssertions: []
  }, null, 2))
})
