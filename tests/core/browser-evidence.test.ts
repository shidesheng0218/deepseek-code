import { describe, expect, test } from 'vitest';
import { collectBrowserEvidence } from '../../src/core/browser-evidence';

describe('browser evidence', () => {
  test('collects DOM, console and network evidence through an injected browser', async () => {
    const events: string[] = [];
    const result = await collectBrowserEvidence({ url: 'https://example.test', expectedText: 'Welcome' }, {
      launch: async () => ({
        newPage: async () => ({
          on: (event: string, listener: (value: { type?: () => string; url?: () => string; status?: () => number }) => void) => { events.push(event); if (event === 'console') listener({ type: () => 'error' }); if (event === 'response') listener({ url: () => 'https://example.test/api', status: () => 200 }); },
          goto: async () => undefined,
          content: async () => '<main>Welcome</main>',
          screenshot: async () => Buffer.from('image')
        }),
        close: async () => undefined
      })
    });
    expect(result.ok).toBe(true);
    expect(result.console).toContain('error');
    expect(result.network).toContainEqual({ url: 'https://example.test/api', status: 200 });
    expect(result.html).toContain('Welcome');
    expect(events).toEqual(expect.arrayContaining(['console', 'response']));
  });
});
