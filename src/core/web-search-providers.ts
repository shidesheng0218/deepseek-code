/**
 * 搜索 Provider 层：BYOK 接入 Tavily / Brave / Exa，
 * 无 API Key 时回退 DuckDuckGo HTML。只负责请求与规范化，
 * 安全校验、去重、注入标记由工具层统一处理。
 */

export interface SearchResultItem {
  title: string;
  url: string;
  snippet: string;
  /** 0-1 的可信度提示，用于排序 */
  score: number;
}

export interface SearchProviderResponse {
  provider: string;
  results: SearchResultItem[];
}

type FetchLike = typeof fetch;

function normalizeURL(value: string): string {
  try {
    const url = new URL(value);
    url.hash = '';
    // 去掉常见跟踪参数
    for (const key of [...url.searchParams.keys()]) if (/^(utm_|fbclid|gclid|ref$)/i.test(key)) url.searchParams.delete(key);
    return url.toString().replace(/\/$/, '');
  } catch { return value.trim(); }
}

export function dedupeAndRank(items: SearchResultItem[]): SearchResultItem[] {
  const seen = new Map<string, SearchResultItem>();
  for (const item of items) {
    const key = normalizeURL(item.url);
    const existing = seen.get(key);
    if (!existing || item.score > existing.score) seen.set(key, { ...item, url: key });
  }
  return [...seen.values()].sort((a, b) => b.score - a.score).slice(0, 8);
}

async function searchTavily(query: string, apiKey: string, fetchImpl: FetchLike): Promise<SearchProviderResponse> {
  const response = await fetchImpl('https://api.tavily.com/search', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ api_key: apiKey, query, max_results: 8, search_depth: 'basic' }),
    signal: AbortSignal.timeout(20_000)
  });
  if (!response.ok) throw new Error(`Tavily returned ${response.status}`);
  const data = await response.json() as { results?: Array<{ title?: string; url?: string; content?: string; score?: number }> };
  const results = (data.results ?? []).flatMap((item) => item.url ? [{ title: item.title ?? item.url, url: item.url, snippet: item.content ?? '', score: typeof item.score === 'number' ? item.score : 0.5 }] : []);
  return { provider: 'tavily', results };
}

async function searchBrave(query: string, apiKey: string, fetchImpl: FetchLike): Promise<SearchProviderResponse> {
  const url = new URL('https://api.search.brave.com/res/v1/web/search');
  url.searchParams.set('q', query);
  url.searchParams.set('count', '8');
  const response = await fetchImpl(url, { headers: { 'x-subscription-token': apiKey, accept: 'application/json' }, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`Brave returned ${response.status}`);
  const data = await response.json() as { web?: { results?: Array<{ title?: string; url?: string; description?: string; page_age?: string }> } };
  const results = (data.web?.results ?? []).flatMap((item) => item.url ? [{ title: item.title ?? item.url, url: item.url, snippet: item.description ?? '', score: item.page_age ? 0.7 : 0.5 }] : []);
  return { provider: 'brave', results };
}

async function searchExa(query: string, apiKey: string, fetchImpl: FetchLike): Promise<SearchProviderResponse> {
  const response = await fetchImpl('https://api.exa.ai/search', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': apiKey },
    body: JSON.stringify({ query, numResults: 8, useAutoprompt: true }),
    signal: AbortSignal.timeout(20_000)
  });
  if (!response.ok) throw new Error(`Exa returned ${response.status}`);
  const data = await response.json() as { results?: Array<{ title?: string; url?: string; text?: string; score?: number }> };
  const results = (data.results ?? []).flatMap((item) => item.url ? [{ title: item.title ?? item.url, url: item.url, snippet: item.text ?? '', score: typeof item.score === 'number' ? item.score : 0.5 }] : []);
  return { provider: 'exa', results };
}

export async function searchWithProvider(query: string, env: NodeJS.ProcessEnv, fetchImpl: FetchLike): Promise<SearchProviderResponse | undefined> {
  if (env.DEEPSEEK_TAVILY_API_KEY) return searchTavily(query, env.DEEPSEEK_TAVILY_API_KEY, fetchImpl);
  if (env.DEEPSEEK_BRAVE_API_KEY) return searchBrave(query, env.DEEPSEEK_BRAVE_API_KEY, fetchImpl);
  if (env.DEEPSEEK_EXA_API_KEY) return searchExa(query, env.DEEPSEEK_EXA_API_KEY, fetchImpl);
  return undefined;
}
