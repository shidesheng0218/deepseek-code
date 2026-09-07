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

/**
 * 已知模型的官方刊例价（USD / 1M tokens），取自 api-docs.deepseek.com/quick_start/pricing。
 * 只收录能确认的 DeepSeek 官方价格；未知模型一律返回 undefined，
 * 上层跳过估算——宁可不显示成本，也不显示一个编造的数字。
 * 价格调整时只需改这张表。
 *
 * DeepSeek 按峰谷时段计价（峰时 01:00-04:00、06:00-10:00 UTC 周一至周五，
 * 其余为谷时，价格为峰时的一半）；这里取峰时价（更贵的一档）做估算，
 * 保证展示给用户的成本永远不低于实际花费，不做分时精确计价。
 *
 * deepseek-chat / deepseek-reasoner 已于 2026-07-24 15:59 UTC 下线，
 * 当前分别映射为 deepseek-v4-flash（非思考模式）与其思考模式；
 * 仍按旧名保留一条兼容映射，避免历史会话记录里的旧模型名查不到价格。
 */
export const MODEL_PRICING: Record<string, ModelPricing> = {
  'deepseek-v4-flash': { inputPerMillion: 0.44, cachedInputPerMillion: 0.014, outputPerMillion: 1.32 },
  'deepseek-v4-pro': { inputPerMillion: 1.32, cachedInputPerMillion: 0.044, outputPerMillion: 3.96 },
  'deepseek-v4-flash-vision-exp': { inputPerMillion: 0.44, cachedInputPerMillion: 0.014, outputPerMillion: 1.32 },
  // 历史模型名兼容映射（已下线，价格为下线前最后已知刊例价，仅用于旧会话回溯估算）
  'deepseek-chat': { inputPerMillion: 0.44, cachedInputPerMillion: 0.014, outputPerMillion: 1.32 },
  'deepseek-reasoner': { inputPerMillion: 1.32, cachedInputPerMillion: 0.044, outputPerMillion: 3.96 }
};

export function pricingForModel(model: string): ModelPricing | undefined {
  return MODEL_PRICING[model.trim().toLowerCase()];
}

export function estimateUsageCost(pricing: ModelPricing, usage: Pick<UsageRecord, 'inputTokens' | 'cachedInputTokens' | 'outputTokens'>): number {
  // prompt_tokens 包含缓存命中部分，须先扣除，避免缓存 token 被按全价再计一次。
  const uncachedInput = Math.max(0, usage.inputTokens - usage.cachedInputTokens);
  const estimatedCost =
    (uncachedInput * pricing.inputPerMillion +
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
