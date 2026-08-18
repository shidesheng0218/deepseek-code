import { access } from 'node:fs/promises';
import type { BrowserLauncher } from './browser-evidence';

function candidatePaths(): string[] {
  return [
    process.env.DEEPSEEK_BROWSER_EXECUTABLE ?? '',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium'
  ].filter(Boolean);
}

export async function localChromiumLauncher(): Promise<ReturnType<BrowserLauncher['launch']> extends Promise<infer T> ? T : never> {
  let executablePath: string | undefined;
  for (const candidate of candidatePaths()) {
    try { await access(candidate); executablePath = candidate; break; } catch { /* Try the next browser. */ }
  }
  if (!executablePath) throw new Error('Browser capability requires Google Chrome, Chromium, or DEEPSEEK_BROWSER_EXECUTABLE.');
  const moduleName = process.env.DEEPSEEK_PLAYWRIGHT_MODULE ?? 'playwright-core';
  try {
    const playwright = await import(moduleName) as { chromium?: { launch(options: { executablePath: string; headless: boolean }): Promise<unknown> } };
    if (!playwright.chromium) throw new Error('Chromium launcher is unavailable');
    return await playwright.chromium.launch({ executablePath, headless: true }) as ReturnType<BrowserLauncher['launch']> extends Promise<infer T> ? T : never;
  } catch {
    throw new Error('Browser capability requires a local Playwright runtime. Set DEEPSEEK_PLAYWRIGHT_MODULE when using a bundled or external runner.');
  }
}
