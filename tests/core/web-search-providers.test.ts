import { describe, expect, test } from 'vitest';
import { dedupeAndRank, searchWithProvider } from '../../src/core/web-search-providers';

describe('web search providers', () => {
  test('dedupes by normalized URL and keeps the highest score', () => {
    const results = dedupeAndRank([
      { title: 'A', url: 'https://example.com/page?utm_source=x', snippet: 'a', score: 0.4 },
      { title: 'A2', url: 'https://example.com/page', snippet: 'a2', score: 0.9 },
      { title: 'B', url: 'https://other.com/', snippet: 'b', score: 0.6 }
    ]);
    expect(results).toHaveLength(2);
    expect(results[0]?.title).toBe('A2');
    expect(results[0]?.url).toBe('https://example.com/page');
  });

  test('uses Tavily when its key is present', async () => {
    const fakeFetch = (async () => new Response(JSON.stringify({ results: [{ title: 'T', url: 'https://tavily.test/doc', content: 'snippet', score: 0.8 }] }), { status: 200 })) as typeof fetch;
    const response = await searchWithProvider('query', { DEEPSEEK_TAVILY_API_KEY: 'key' }, fakeFetch);
    expect(response?.provider).toBe('tavily');
    expect(response?.results[0]?.url).toBe('https://tavily.test/doc');
  });

  test('returns undefined when no provider key is configured', async () => {
    const response = await searchWithProvider('query', {}, (async () => new Response('{}')) as typeof fetch);
    expect(response).toBeUndefined();
  });
});
