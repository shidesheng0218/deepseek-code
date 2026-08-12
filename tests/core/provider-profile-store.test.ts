import { describe, expect, test } from 'vitest';
import { ProviderProfileStore } from '../../src/core/providers/provider-profile-store';

describe('provider profile store', () => {
  test('persists provider configuration without persisting the API key', () => {
    const store = new ProviderProfileStore(':memory:');
    store.save({
      id: 'deepseek-default',
      name: 'DeepSeek 官方',
      baseUrl: 'https://api.deepseek.com/v1/',
      protocol: 'openai-compatible',
      model: 'deepseek-chat',
      apiKeyRef: 'keychain://deepseek-default',
      inputPerMillion: 0.28,
      cachedInputPerMillion: 0.028,
      outputPerMillion: 0.42
    });

    expect(store.list()).toEqual([expect.objectContaining({ id: 'deepseek-default', model: 'deepseek-chat' })]);
    expect(JSON.stringify(store.list())).not.toContain('sk-secret');
    store.close();
  });
});
