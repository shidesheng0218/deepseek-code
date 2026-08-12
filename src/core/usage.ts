export type ModelFeature = 'main_agent' | 'explore' | 'review' | 'summary';

export interface ModelPricing {
  inputPerMillion: number;
  cachedInputPerMillion: number;
  outputPerMillion: number;
}

export interface UsageRecord {
  sessionId: string;
  feature: ModelFeature;
  model: string;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  latencyMs: number;
}

export function estimateUsageCost(pricing: ModelPricing, usage: Pick<UsageRecord, 'inputTokens' | 'cachedInputTokens' | 'outputTokens'>): number {
  const estimatedCost =
    (usage.inputTokens * pricing.inputPerMillion +
      usage.cachedInputTokens * pricing.cachedInputPerMillion +
      usage.outputTokens * pricing.outputPerMillion) /
    1_000_000;
  return Number(estimatedCost.toFixed(6));
}

export class UsageLedger {
  private readonly records = new Map<string, UsageRecord[]>();

  constructor(private readonly pricing: ModelPricing) {}

  record(record: UsageRecord): void {
    const existing = this.records.get(record.sessionId) ?? [];
    existing.push(record);
    this.records.set(record.sessionId, existing);
  }

  summary(sessionId: string): { inputTokens: number; cachedInputTokens: number; outputTokens: number; estimatedCost: number } {
    const totals = (this.records.get(sessionId) ?? []).reduce(
      (summary, record) => ({
        inputTokens: summary.inputTokens + record.inputTokens,
        cachedInputTokens: summary.cachedInputTokens + record.cachedInputTokens,
        outputTokens: summary.outputTokens + record.outputTokens
      }),
      { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0 }
    );
    return { ...totals, estimatedCost: estimateUsageCost(this.pricing, totals) };
  }
}

export function chooseModelTier(feature: ModelFeature): 'fast' | 'pro' {
  return feature === 'explore' || feature === 'summary' ? 'fast' : 'pro';
}
