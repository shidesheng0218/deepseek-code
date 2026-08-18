import { access } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { BrowserLauncher } from './browser-evidence';

export function browserExecutableCandidates(execPath = process.execPath): string[] {
  const bundledResource = join(dirname(execPath), '..', 'Resources', 'browser', 'chrome-headless-shell');
  const configuredRuntime = process.env.DEEPSEEK_BROWSER_RUNTIME_DIR
    ? join(process.env.DEEPSEEK_BROWSER_RUNTIME_DIR, 'chrome-headless-shell')
    : '';
  return [
    process.env.DEEPSEEK_BROWSER_EXECUTABLE ?? '',
    configuredRuntime,
    bundledResource,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium'
  ].filter(Boolean);
}

export function playwrightModuleCandidates(execPath = process.execPath): string[] {
  return [
    process.env.DEEPSEEK_PLAYWRIGHT_MODULE ?? '',
    join(dirname(execPath), '..', 'Resources', 'playwright-core', 'index.js'),
    'playwright-core'
  ].filter(Boolean);
}

export async function localChromiumLauncher(): Promise<ReturnType<BrowserLauncher['launch']> extends Promise<infer T> ? T : never> {
  let executablePath: string | undefined;
  for (const candidate of browserExecutableCandidates()) {
    try { await access(candidate); executablePath = candidate; break; } catch { /* Try the next browser. */ }
  }
  if (!executablePath) throw new Error('Browser capability requires Google Chrome, Chromium, or DEEPSEEK_BROWSER_EXECUTABLE.');
  for (const moduleName of playwrightModuleCandidates()) {
    try {
      const playwright = await import(moduleName) as { chromium?: { launch(options: { executablePath: string; headless: boolean }): Promise<unknown> } };
      if (!playwright.chromium) continue;
      return await playwright.chromium.launch({ executablePath, headless: true }) as ReturnType<BrowserLauncher['launch']> extends Promise<infer T> ? T : never;
    } catch { /* Try the next packaged or local module candidate. */ }
  }
  throw new Error('Browser capability requires a bundled or local Playwright Core runtime.');
}
