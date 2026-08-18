export interface BrowserEvidence { ok: boolean; url: string; html: string; console: string[]; network: Array<{ url: string; status: number }>; screenshot: Buffer; error?: string }

interface BrowserPage {
  on(event: 'console' | 'response', listener: (value: { type?: () => string; url?: () => string; status?: () => number }) => void): void;
  goto(url: string, options: { waitUntil: 'domcontentloaded'; timeout: number }): Promise<unknown>;
  content(): Promise<string>;
  screenshot(options: { type: 'png'; fullPage: boolean }): Promise<Buffer>;
}

interface BrowserInstance { newPage(): Promise<BrowserPage>; close(): Promise<void> }
export interface BrowserLauncher { launch(): Promise<BrowserInstance> }

export async function collectBrowserEvidence(input: { url: string; expectedText?: string }, options: { launch: () => Promise<BrowserInstance> }): Promise<BrowserEvidence> {
  const browser = await options.launch();
  try {
    const page = await browser.newPage();
    const console: string[] = [];
    const network: Array<{ url: string; status: number }> = [];
    page.on('console', (message) => { if (message.type?.()) console.push(message.type()); });
    page.on('response', (response) => { const url = response.url?.(); const status = response.status?.(); if (url && typeof status === 'number') network.push({ url, status }); });
    await page.goto(input.url, { waitUntil: 'domcontentloaded', timeout: 30_000 });
    const html = await page.content();
    const screenshot = await page.screenshot({ type: 'png', fullPage: true });
    if (input.expectedText && !html.includes(input.expectedText)) return { ok: false, url: input.url, html, console, network, screenshot, error: `Expected text was not found: ${input.expectedText}` };
    return { ok: true, url: input.url, html, console, network, screenshot };
  } catch (error) {
    return { ok: false, url: input.url, html: '', console: [], network: [], screenshot: Buffer.alloc(0), error: error instanceof Error ? error.message : String(error) };
  } finally { await browser.close(); }
}
