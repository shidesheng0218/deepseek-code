/**
 * Shadow Eval（NEXT_GEN_ARCHITECTURE Phase 4）
 *
 * 离线策略对比：用已录制的会话历史，在不重新调用模型的前提下，
 * 对比不同上下文策略的真实效果。
 *
 * 重要边界（读代码前必须知道）：
 * 录制回放只能重放已经录制好的模型输出——给它换一套系统指令、
 * 换一套工具顺序，它吐出的 delta 序列不会变，因为模型从未真的被重新调用过。
 * 所以"指令模板"“工具顺序"“模型档位"这三类变体，靠纯回放**无法**产生任何
 * 真实差异——之前的版本把这几类也塞进对比表、编出几乎相同的数字，那是假的。
 *
 * 唯一在纯回放下真实可测的变体是"上下文窗口大小"：buildContext() 只是对
 * 已录制的对话历史做裁剪，不依赖模型调用，所以可以用不同的 ContextBudget
 * 重跑一遍裁剪逻辑，测出真实的字符数差异——这部分是真数据。
 */

import type { AgentMessage } from './agent-executor';
import { buildContext, DEFAULT_CONTEXT_BUDGET, type ContextBudget } from './context-builder';

export interface StrategyVariant {
  name: string;
  description: string;
  modifications: {
    instructionTemplate?: string; // 替换系统指令模板——纯回放无法评估，见下方 evaluable
    toolOrder?: string[]; // 重排工具顺序——纯回放无法评估
    contextWindowSize?: number; // 修改上下文预算（字符数）——纯回放可真实评估
    modelTier?: string; // 替换模型——纯回放无法评估
  };
}

export interface ShadowEvalResult {
  variantName: string;
  /** 该变体是否能在纯回放下产生真实差异；false 时下面的数字等于基线，不代表"测过了没差别"。 */
  evaluable: boolean;
  /** evaluable=false 时说明为什么（例如"需要真实模型调用，回放无法验证"）。 */
  inapplicableReason?: string;
  tokenUsage: {
    input: number;
    output: number;
    total: number;
  };
  /** 应用该变体的 ContextBudget 后，实际组装进模型的上下文字符数（真实裁剪结果）。 */
  contextChars: number;
  toolCallCount: number;
  durationMs: number;
}

export interface ShadowEvalComparison {
  baselineVariant: string;
  variants: ShadowEvalResult[];
  /** 综合评分最高的可评估变体；如果没有任何变体可评估，退回 baseline，并在 reasoning 里说明。 */
  winner: string;
  reasoning: string;
}

const VARIANT_KINDS_REQUIRING_LIVE_MODEL = ['instructionTemplate', 'toolOrder', 'modelTier'] as const;

function whyNotEvaluable(variant: StrategyVariant): string | undefined {
  const blocking = VARIANT_KINDS_REQUIRING_LIVE_MODEL.find((key) => variant.modifications[key] !== undefined);
  if (!blocking) return undefined;
  return `修改 ${blocking} 需要真实模型调用产生不同的输出；录制回放只回放已录制的 delta，纯回放下无法验证这类变体`;
}

/**
 * Shadow Eval 服务
 */
export class ShadowEvaluator {
  /**
   * 运行 Shadow Eval：对比多个策略变体。
   * conversation 是该会话的真实历史（eventStore.loadConversation 的结果）——
   * 只有传入这个才能真正测出 contextWindowSize 变体的裁剪效果；不传时该项退化为不可评估。
   */
  async evaluate(params: {
    sessionID: string;
    recordedTurns: Array<{ turnSequence: number; model: string; deltas: Array<{ type: string; [key: string]: unknown }> }>;
    variants: StrategyVariant[];
    conversation?: AgentMessage[];
  }): Promise<ShadowEvalComparison> {
    const results: ShadowEvalResult[] = [];

    // 录制内容里的 token/工具调用数是真实发生过的，对所有变体都一样
    // （因为回放不会改变模型实际吐出的 delta），所以只算一次。
    let inputTokens = 0;
    let outputTokens = 0;
    let toolCallCount = 0;
    for (const turn of params.recordedTurns) {
      for (const delta of turn.deltas) {
        if (delta.type === 'usage') {
          inputTokens += (delta.inputTokens as number) ?? 0;
          outputTokens += (delta.outputTokens as number) ?? 0;
        } else if (delta.type === 'tool_call') {
          toolCallCount += 1;
        }
      }
    }

    const baselineContextChars = params.conversation
      ? buildContext(params.conversation, DEFAULT_CONTEXT_BUDGET).reduce((sum, m) => sum + m.content.length, 0)
      : 0;

    for (const variant of params.variants) {
      const startTime = Date.now();
      const reason = whyNotEvaluable(variant);

      let contextChars = baselineContextChars;
      if (!reason && params.conversation) {
        // contextWindowSize（或无修改的 baseline）在纯回放下是可以真实评估的：
        // 用这个变体的预算重新跑一次真实的裁剪逻辑，得到实际字符数。
        const budget: ContextBudget = variant.modifications.contextWindowSize !== undefined
          ? { ...DEFAULT_CONTEXT_BUDGET, maxChars: variant.modifications.contextWindowSize }
          : DEFAULT_CONTEXT_BUDGET;
        contextChars = buildContext(params.conversation, budget).reduce((sum, m) => sum + m.content.length, 0);
      }

      results.push({
        variantName: variant.name,
        evaluable: !reason,
        ...(reason ? { inapplicableReason: reason } : {}),
        tokenUsage: { input: inputTokens, output: outputTokens, total: inputTokens + outputTokens },
        contextChars,
        toolCallCount,
        durationMs: Date.now() - startTime
      });
    }

    // 只在可评估的变体里挑胜者：按裁剪后上下文字符数最小者胜——
    // token/工具调用数在所有变体间相同（回放决定），唯一有真实区分度的维度就是 contextChars。
    const evaluableResults = results.filter((r) => r.evaluable);
    const winnerResult = evaluableResults.length > 0
      ? evaluableResults.reduce((best, r) => (r.contextChars < best.contextChars ? r : best))
      : undefined;
    const winner = winnerResult?.variantName ?? params.variants[0]?.name ?? 'baseline';

    const skipped = results.filter((r) => !r.evaluable);
    const reasoning = evaluableResults.length > 0
      ? `胜者：${winner}（上下文裁剪后 ${winnerResult?.contextChars} 字符，为可评估变体中最小）\n` +
        evaluableResults.map((r) => `- ${r.variantName}: 上下文 ${r.contextChars} 字符`).join('\n') +
        (skipped.length > 0 ? `\n\n以下变体无法在纯回放下评估：\n${skipped.map((r) => `- ${r.variantName}: ${r.inapplicableReason}`).join('\n')}` : '')
      : `无可评估变体——全部 ${results.length} 个变体都需要真实模型调用（instructionTemplate/toolOrder/modelTier），纯回放无法验证。退回 baseline。`;

    return {
      baselineVariant: params.variants[0]?.name ?? 'baseline',
      variants: results,
      winner,
      reasoning
    };
  }

  /**
   * 预定义策略变体（常见优化方向）。
   * 注意：compressed-instructions / tool-order-optimized 这两个在纯回放下
   * evaluable 恒为 false（见 evaluate() 里的说明），保留它们是为了展示
   * "这个方向值得做，但要接真实模型才能验证"，不是已验证的结论。
   */
  static commonVariants(): StrategyVariant[] {
    return [
      {
        name: 'baseline',
        description: '当前策略（基线），使用默认 ContextBudget',
        modifications: {}
      },
      {
        name: 'smaller-context',
        description: '缩小上下文窗口（8000 字符 vs baseline 120000）——纯回放可真实评估',
        modifications: {
          contextWindowSize: 8_000
        }
      },
      {
        name: 'compressed-instructions',
        description: '压缩指令（减少系统提示长度）——需要真实模型调用才能验证效果',
        modifications: {
          instructionTemplate: 'COMPRESSED'
        }
      },
      {
        name: 'tool-order-optimized',
        description: '工具顺序优化（高频工具前置）——需要真实模型调用才能验证效果',
        modifications: {
          toolOrder: ['read_file', 'search_workspace', 'apply_patch', 'run_command']
        }
      }
    ];
  }

  /**
   * 从事件日志提取录制的 turn
   */
  static extractRecordedTurns(events: Array<{ type: string; payload?: Record<string, unknown> }>): Array<{
    turnSequence: number;
    model: string;
    deltas: Array<{ type: string; [key: string]: unknown }>;
  }> {
    return events
      .filter((event) => event.type === 'model_stream_recorded')
      .map((event) => ({
        turnSequence: (event.payload?.turnSequence as number) ?? 0,
        model: (event.payload?.model as string) ?? 'unknown',
        deltas: (event.payload?.deltas as Array<{ type: string; [key: string]: unknown }>) ?? []
      }));
  }
}

/**
 * 全局实例
 */
export const shadowEvaluator = new ShadowEvaluator();
