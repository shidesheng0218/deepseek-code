/**
 * Tournament Orchestration（NEXT_GEN_ARCHITECTURE Phase 2 支柱三）
 *
 * 多假设竞争 + 证据裁决 + 确定性合并
 *
 * vs Codex：
 * - Codex 有并行无裁决语义，过程不可见
 * - 我们输出裁决证据链 + negative evidence（败者为什么不通）
 *
 * vs Claude Code subagent：
 * - Subagent 是"委派-汇报"
 * - 锦标赛是"竞争-证伪"，难题成功率结构性更高
 */

export type TournamentStatus = 'running' | 'judging' | 'merged' | 'aborted';

export interface Hypothesis {
  id: string;
  approach: string; // 一句话方案，例如 "从会话缓存层修" vs "从事件总线修"
  forkedSessionID: string; // 从主会话分叉，继承全部上下文
  worktreePath?: string; // 独立工作树（可选，简单任务直接共享）
  branch: string; // deepseek/arena-<tournamentID>-h<n>
  result?: {
    patchHash: string;
    testExitCode: number;
    diffStat: string;
    tokensUsed: number;
    deliveryState: string; // delivered / needsRepair / needsAttention
  };
}

export interface Tournament {
  tournamentID: string;
  parentSessionID: string;
  prompt: string;
  hypotheses: Hypothesis[];
  status: TournamentStatus;
  winner?: string; // hypothesis.id
  judgeReasoning?: string;
  negativeEvidence: Array<{
    hypothesisID: string;
    approach: string;
    reason: string; // 为什么这条路不通
  }>;
  createdAt: string;
  completedAt?: string;
}

export interface JudgeInput {
  requirement: string;
  hypotheses: Array<{
    id: string;
    approach: string;
    diff: string;
    testExitCode: number;
    diffStat: string;
    deliveryState: string;
  }>;
}

export interface JudgeVerdict {
  winner: string; // hypothesis.id
  scores: Array<{
    hypothesisID: string;
    testsPass: number; // 0-10
    diffMinimality: number; // 0-10（越小越好）
    evidenceCoverage: number; // 0-10
    riskNotes: string[];
  }>;
  reasoning: string;
}

/**
 * 锦标赛编排器
 */
export class TournamentOrchestrator {
  /**
   * 触发条件：code_change 且预估影响面 > 阈值
   * 简单任务绝不进锦标赛——成本控制纪律
   */
  shouldTrigger(context: {
    taskType: string;
    estimatedImpact?: number;
    explicitArena?: boolean;
  }): boolean {
    // 用户显式 /arena
    if (context.explicitArena) return true;

    // code_change 且影响符号数 > 5（需要代码图谱支持）
    if (context.taskType === 'code_change' && context.estimatedImpact && context.estimatedImpact > 5) {
      return true;
    }

    return false;
  }

  /**
   * 生成互斥假设（2-3 条）
   * Phase 2 v1：占位实现，返回固定模板
   * Phase 2 v2：调用规划模型生成
   */
  generateHypotheses(prompt: string, context: { estimatedImpact?: number }): string[] {
    // TODO: 调用规划模型（DeepSeek R1 / Claude Opus）
    // 当前占位：返回两条通用假设
    return [
      '方案 A：从数据层修复（修改数据结构或查询逻辑）',
      '方案 B：从 UI 层修复（调整组件状态或事件处理）'
    ];
  }

  /**
   * 裁决胜者
   * Phase 2 v1：规则裁决（测试通过 > diff 更小）
   * Phase 2 v2：独立模型调用
   */
  judge(input: JudgeInput): JudgeVerdict {
    const scores = input.hypotheses.map((h) => {
      // 测试通过得分：exitCode === 0 → 10 分
      const testsPass = h.testExitCode === 0 ? 10 : 0;

      // diff 最小性：用 diffStat 的文件数 + 行数反推
      const diffLines = this.extractDiffLines(h.diffStat);
      const diffMinimality = Math.max(0, 10 - Math.floor(diffLines / 10));

      // 交付状态得分：delivered → 10，handoffReady → 7，needsRepair → 3
      const deliveryScore =
        h.deliveryState === 'delivered' ? 10 : h.deliveryState === 'handoffReady' ? 7 : 3;

      const total = testsPass + diffMinimality + deliveryScore;

      return {
        hypothesisID: h.id,
        testsPass,
        diffMinimality,
        evidenceCoverage: deliveryScore,
        riskNotes: h.testExitCode !== 0 ? ['测试失败'] : [],
        total
      };
    });

    // 按总分排序
    scores.sort((a, b) => b.total - a.total);
    const winner = scores[0];

    if (!winner) {
      throw new Error('No hypotheses to judge');
    }

    const reasoning = `胜者：${winner.hypothesisID}（总分 ${winner.total}）\n` +
      `- 测试通过: ${winner.testsPass}/10\n` +
      `- Diff 最小性: ${winner.diffMinimality}/10\n` +
      `- 交付状态: ${winner.evidenceCoverage}/10`;

    return {
      winner: winner.hypothesisID,
      scores,
      reasoning
    };
  }

  private extractDiffLines(diffStat: string): number {
    // 从 "3 files changed, 42 insertions(+), 15 deletions(-)" 提取总行数
    const match = diffStat.match(/(\d+) insertion|(\d+) deletion/g);
    if (!match) return 0;
    return match.reduce((sum, part) => sum + parseInt(part.match(/\d+/)?.[0] ?? '0'), 0);
  }
}
