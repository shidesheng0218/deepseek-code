import { createHash } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { dedupeAndRank, searchWithProvider, type SearchResultItem } from '../web-search-providers';

type ResolveHost = (host: string) => Promise<string[]>;

export interface WebTools {
  web_search(input: Record<string, unknown>): Promise<unknown>;
  web_fetch(input: Record<string, unknown>): Promise<unknown>;
}

function isPrivateAddress(address: string): boolean {
  const value = address.toLowerCase();
  if (value === '::1' || value === '::' || value.startsWith('fe80:') || value.startsWith('fc') || value.startsWith('fd')) return true;
  const octets = value.split('.').map(Number);
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return false;
  const first = octets[0] ?? -1;
  const second = octets[1] ?? -1;
  return first === 0 || first === 10 || first === 127 || first === 169 && second === 254 || first === 172 && second >= 16 && second <= 31 || first === 192 && second === 168 || first >= 224;
}

export function isSafePublicURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    const host = url.hostname.toLowerCase();
    return host !== 'localhost' && !host.endsWith('.localhost') && !isPrivateAddress(host);
  } catch { return false; }
}

function htmlToText(value: string): { title: string; content: string } {
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(value)?.[1]?.replace(/\s+/g, ' ').trim() ?? '';
  const content = value
    .replace(/<(script|style|noscript|svg|template)[^>]*>[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<\/(p|div|h[1-6]|li|br|tr|section|article)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*/g, '\n')
    .trim();
  return { title, content: content.slice(0, 200_000) };
}

function inputString(input: Record<string, unknown>, name: string): string {
  return typeof input[name] === 'string' ? input[name].trim() : '';
}

const INJECTION_PATTERNS = [
  /ignore (all|any|previous|the above) instructions?/i,
  /忽略(之前|以上|所有)(的)?(指令|指示|规则)/,
  /you are now|new persona|system prompt/i,
  /disregard (your|all) (guidelines|rules|training)/i
];

export function detectPromptInjection(text: string): string[] {
  return INJECTION_PATTERNS.filter((pattern) => pattern.test(text)).map((pattern) => pattern.source);
}

function withCitations(results: SearchResultItem[], retrievedAt: string): Array<SearchResultItem & { citationID: string; retrievedAt: string; injectionWarnings: string[] }> {
  return results.map((item) => ({
    ...item,
    citationID: createHash('sha256').update(`${item.url}\n${item.snippet}`).digest('hex').slice(0, 16),
    retrievedAt,
    injectionWarnings: detectPromptInjection(`${item.title}\n${item.snippet}`)
  }));
}

async function defaultResolveHost(host: string): Promise<string[]> {
  const addresses = await lookup(host, { all: true, verbatim: true });
  return addresses.map((entry) => entry.address);
}

export function createWebTools(options: { fetchImpl?: typeof fetch; resolveHost?: ResolveHost } = {}): WebTools {
  const fetchImpl = options.fetchImpl ?? fetch;
  const resolveHost = options.resolveHost ?? defaultResolveHost;

  async function assertSafe(url: URL): Promise<void> {
    if (!isSafePublicURL(url.toString())) throw new Error('Blocked unsafe URL');
    const addresses = await resolveHost(url.hostname);
    if (addresses.length === 0 || addresses.some(isPrivateAddress)) throw new Error('Blocked unsafe DNS target');
  }

  return {
    async web_search(input) {
      const query = inputString(input, 'query');
      if (!query) throw new Error('web_search requires query');
      const retrievedAt = new Date().toISOString();
      // BYOK API Provider 优先；未配置时回退 DuckDuckGo HTML 解析
      const providerResponse = await searchWithProvider(query, process.env, fetchImpl).catch(() => undefined);
      if (providerResponse && providerResponse.results.length) {
        const ranked = dedupeAndRank(providerResponse.results).filter((item) => isSafePublicURL(item.url));
        return { ok: true, query, results: withCitations(ranked, retrievedAt), provider: providerResponse.provider, retrievedAt };
      }
      const url = new URL('https://html.duckduckgo.com/html/');
      url.searchParams.set('q', query);
      await assertSafe(url);
      const response = await fetchImpl(url, { headers: { 'user-agent': 'DeepSeek-Code/0.1' }, redirect: 'error', signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`Search provider returned ${response.status}`);
      const html = await response.text();
      const results: SearchResultItem[] = [];
      const anchors = html.matchAll(/<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi);
      for (const anchor of anchors) {
        const raw = anchor[1];
        const markup = anchor[2];
        if (!raw || !markup) continue;
        const candidate = raw.startsWith('/l/?') ? new URL(raw, url).searchParams.get('uddg') ?? raw : raw;
        if (!isSafePublicURL(candidate)) continue;
        const title = htmlToText(markup).content;
        results.push({ title, url: candidate, snippet: '', score: 0.5 });
        if (results.length === 8) break;
      }
      return { ok: true, query, results: withCitations(dedupeAndRank(results), retrievedAt), provider: 'duckduckgo-html', retrievedAt };
    },

    async web_fetch(input) {
      let url = new URL(inputString(input, 'url'));
      const redirects: string[] = [];
      for (let attempt = 0; attempt < 5; attempt += 1) {
        await assertSafe(url);
        const response = await fetchImpl(url, { headers: { 'user-agent': 'DeepSeek-Code/0.1', accept: 'text/html,application/json,text/plain,application/pdf;q=0.5' }, redirect: 'manual', signal: AbortSignal.timeout(30_000) });
        if (response.status >= 300 && response.status < 400) {
          const location = response.headers.get('location');
          if (!location) throw new Error('Redirect without location');
          redirects.push(url.toString());
          url = new URL(location, url);
          continue;
        }
        if (!response.ok) throw new Error(`Fetch returned ${response.status}`);
        const raw = (await response.text()).slice(0, 220_000);
        const parsed = htmlToText(raw);
        return { ok: true, finalURL: url.toString(), redirects, title: parsed.title, content: parsed.content, truncated: raw.length >= 220_000, retrievedAt: new Date().toISOString(), contentHash: createHash('sha256').update(raw).digest('hex') };
      }
      throw new Error('Too many redirects');
    }
  };
}
