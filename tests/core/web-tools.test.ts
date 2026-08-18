import { describe, expect, test } from 'vitest';
import { createWebTools, isSafePublicURL } from '../../src/core/tools/web';

describe('web tools', () => {
  test('blocks localhost, private and metadata addresses', async () => {
    expect(isSafePublicURL('http://localhost:3000')).toBe(false);
    expect(isSafePublicURL('http://127.0.0.1:8080')).toBe(false);
    expect(isSafePublicURL('http://169.254.169.254/latest/meta-data')).toBe(false);
    expect(isSafePublicURL('http://192.168.1.10')).toBe(false);
    expect(isSafePublicURL('https://example.com/docs')).toBe(true);
  });

  test('returns bounded structured fetch output', async () => {
    const tools = createWebTools({
      fetchImpl: async () => new Response('<html><head><title>Docs</title></head><body><h1>Heading</h1><p>Hello world</p><script>bad()</script></body></html>', { status: 200, headers: { 'content-type': 'text/html' } }),
      resolveHost: async () => ['93.184.216.34']
    });
    const result = await tools.web_fetch({ url: 'https://example.com/docs' }) as { ok: boolean; title: string; content: string; contentHash: string };
    expect(result.ok).toBe(true);
    expect(result.title).toBe('Docs');
    expect(result.content).toContain('Heading');
    expect(result.content).not.toContain('bad()');
    expect(result.contentHash).toMatch(/^[a-f0-9]{64}$/);
  });
});
