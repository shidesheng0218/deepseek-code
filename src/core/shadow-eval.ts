/**
 * Shadow Eval（NEXT_GEN_ARCHITECTURE Phase 4）
 *
 * 离线策略对比：用 RecordingProvider 重跑录制会话，对比不同策略的效果
 *
 * vs Codex：
 * - Codex 无确定性回放能力
 * - 我们可以离线 A/B 测试不同 prompt 模板、工具顺序、上下文策略
 *
 * Phase 4 完整版：
 * - 策略变体定义：修改指令长度、工具顺序、系统提示
 * - 离线回放：用 RecordingProvider 重跑
 * - 指标对比：token 消耗、成功率、工具调用次数、耗时
 */

export interface StrategyVariant {
  name: string;
  description: string;
  modifications: {
    instructionTemplate?: string; // 替换系统指令模板
    toolOrder?: string[]; // 重排工具顺序
    contextWindowSize?: number; // 修改上下文窗口
    modelTier?: string; // 替换模型
  };
}

export interface ShadowEvalResult {
  variantName: string;
  tokenUsage: {
    input: number;
    output: number;
    total: number;
  };
  toolCallCount: number;
  success: boolean;
  deliveryState: string;
  durationMs: number;
  divergencePoints: Array<{
    turnIndex: number;
    reason: string;
    expected: string;
    actual: string;
  }>;
}

export interface ShadowEvalComparison {
  baselineVariant: string;
  variants: ShadowEvalResult[];
  winner: string; // 综合评分最高的变体
  reasoning: string;
}

/**
 * Shadow Eval 服务
 */
export class ShadowEvaluator {
  /**
   * 运行 Shadow Eval：对比多个策略变体
   */
  async evaluate(params: {
    sessionID: string;
    recordedTurns: Array<{ turnSequence: number; model: string; deltas: Array<{ type: string; [key: string]: unknown }> }>;
    variants: StrategyVariant[];
  }): Promise<ShadowEvalComparison> {
    const results: ShadowEvalResult[] = [];

    for (const variant of params.variants) {
      const startTime = Date.now();

      // 1. 构造 RecordingProvider（使用录制的模型流）
      const { RecordingProvider } = await import('./providers/recording-provider');
      const recordingProvider = new RecordingProvider(params.recordedTurns);

      // 2. 应用策略变体修改（当前简化版：只记录，不实际重跑）
      // TODO Phase 4 v2：实际重跑 AgentExecutor with RecordingProvider

      // 3. 统计指标（从录制内容推算）
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

      const durationMs = Date.now() - startTime;

      results.push({
        variantName: variant.name,
        tokenUsage: {
          input: inputTokens,
          output: outputTokens,
          total: inputTokens + outputTokens
        },
        toolCallCount,
        success: true, // TODO: 从事件日志提取实际状态
        deliveryState: 'unknown',
        durationMs,
        divergencePoints: [] // TODO: 对比实际重跑结果
      });
    }

    // 4. 综合评分：token 消耗（权重 40%）+ 成功率（权重 60%）
    const scores = results.map((r) => ({
      variant: r.variantName,
      score: (r.success ? 60 : 0) + (40 * (1 - r.tokenUsage.total / Math.max(...results.map((x) => x.tokenUsage.total))))
    }));

    scores.sort((a, b) => b.score - a.score);
    const winner = scores[0]?.variant ?? params.variants[0]?.name ?? 'baseline';

    const reasoning = `胜者：${winner}\n` +
      results.map((r) => `- ${r.variantName}: ${r.tokenUsage.total} tokens, ${r.toolCallCount} 工具调用`).join('\n');

    return {
      baselineVariant: params.variants[0]?.name ?? 'baseline',
      variants: results,
      winner,
      reasoning
    };
  }

  /**
   * 预定义策略变体（常见优化方向）
   */
  static commonVariants(): StrategyVariant[] {
    return [
      {
        name: 'baseline',
        description: '当前策略（基线）',
        modifications: {}
      },
      {
        name: 'compressed-instructions',
        description: '压缩指令（减少系统提示长度）',
        modifications: {
          instructionTemplate: 'COMPRESSED' // TODO: 实际模板
        }
      },
      {
        name: 'tool-order-optimized',
        description: '工具顺序优化（高频工具前置）',
        modifications: {
          toolOrder: ['read_file', 'search_workspace', 'apply_patch', 'run_command']
        }
      },
      {
        name: 'smaller-context',
        description: '缩小上下文窗口（节省 token）',
        modifications: {
          contextWindowSize: 8000 // vs baseline 16000
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
