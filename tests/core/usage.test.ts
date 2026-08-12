import { describe, expect, test } from 'vitest';
import { UsageLedger, chooseModelTier, estimateUsageCost } from '../../src/core/usage';

describe('usage accounting and routing', () => {
  test('records feature-level token usage and cost', () => {
    const ledger = new UsageLedger({ inputPerMillion: 0.1, cachedInputPerMillion: 0.02, outputPerMillion: 0.2 });
    ledger.record({ sessionId: 's1', feature: 'main_agent', model: 'deepseek-pro', inputTokens: 1_000_000, cachedInputTokens: 500_000, outputTokens: 500_000, latencyMs: 1200 });

    expect(ledger.summary('s1')).toMatchObject({
      inputTokens: 1_000_000,
      cachedInputTokens: 500_000,
      outputTokens: 500_000,
      estimatedCost: 0.21
    });
  });

  test('routes cheap background work separately from complex coding', () => {
    expect(chooseModelTier('explore')).toBe('fast');
    expect(chooseModelTier('summary')).toBe('fast');
    expect(chooseModelTier('main_agent')).toBe('pro');
    expect(chooseModelTier('review')).toBe('pro');
  });

  test('calculates a request cost without mixing cached and uncached input tokens', () => {
    expect(estimateUsageCost(
      { inputPerMillion: 0.1, cachedInputPerMillion: 0.02, outputPerMillion: 0.2 },
      { inputTokens: 100, cachedInputTokens: 50, outputTokens: 25 }
    )).toBe(0.000016);
  });
});
