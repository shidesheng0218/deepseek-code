/**
 * versus 指标汇总（纯函数，供 run.mjs、report.mjs 与 vitest 复用）。
 *
 * 指标口径（与 FULL_SPECTRUM_DOMINANCE.md 的碾压线一致）：
 * - successRate：verify 命令通过的成功运行 / 总运行（harness 自述不算数）。
 * - costPerSolvedUSD：成功任务均摊成本 = 有成本数据的运行总成本 / 成功数。
 * - tokensPerSolved：同上但用 input+output token（无价格时的横向比较口径）。
 * - coverage：tokens/cost/approvals 有数据的运行占比，报告必须展示度量缺口。
 */

export function median(values) {
  const sorted = values.filter((value) => typeof value === 'number' && Number.isFinite(value)).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export function tokensTotal(tokens) {
  return tokens ? tokens.input + tokens.output : null;
}

/** 按 config 的价格表计算单次运行成本（美元）；无价格或无 token 数据返回 null。 */
export function costForTokens(tokens, price) {
  if (!tokens || !price) return null;
  const input = (tokens.input / 1e6) * (price.input ?? 0);
  const output = (tokens.output / 1e6) * (price.output ?? 0);
  const cached = (tokens.cached / 1e6) * (price.cachedInput ?? price.input ?? 0);
  return input + output + cached;
}

/** 单次运行结果归一化：填入 driver 缺失字段的默认值，计算总 token 与成本。 */
export function normalizeResult(result, priceEntry) {
  const tokens = result.tokens ?? null;
  const totalTokens = tokensTotal(tokens);
  const costUSD = typeof result.costUSD === 'number' ? result.costUSD : costForTokens(tokens, priceEntry);
  return { ...result, tokens, totalTokens, costUSD };
}

/**
 * 按 harness 聚合。
 * @param {Array} results normalizeResult 后的运行结果
 * @returns {Array} 每个 harness 一行的统计
 */
export function aggregate(results) {
  const byHarness = new Map();
  for (const result of results) {
    const list = byHarness.get(result.harness) ?? [];
    list.push(result);
    byHarness.set(result.harness, list);
  }
  return [...byHarness.entries()].map(([harness, runs]) => {
    const effectiveTokens = (run) => run.totalTokens ?? tokensTotal(run.tokens);
    const completed = runs.filter((run) => run.status === 'completed');
    const successes = runs.filter((run) => run.success === true);
    const withTokens = runs.filter((run) => effectiveTokens(run) !== null && effectiveTokens(run) !== undefined);
    const withCost = runs.filter((run) => typeof run.costUSD === 'number');
    const withApprovals = runs.filter((run) => typeof run.approvals === 'number');
    const sum = (list, pick) => list.reduce((total, run) => total + pick(run), 0);
    const totalTokensSum = sum(withTokens, (run) => effectiveTokens(run));
    const totalCost = sum(withCost, (run) => run.costUSD);
    const withBreakdown = runs.filter((run) => run.tokens !== null && run.tokens !== undefined);
    return {
      harness,
      runs: runs.length,
      errors: runs.filter((run) => run.status === 'error').length,
      successes: successes.length,
      successRate: runs.length ? successes.length / runs.length : 0,
      avgApprovals: withApprovals.length ? sum(withApprovals, (run) => run.approvals) / withApprovals.length : null,
      avgInputTokens: withBreakdown.length ? sum(withBreakdown, (run) => run.tokens.input) / withBreakdown.length : null,
      avgOutputTokens: withBreakdown.length ? sum(withBreakdown, (run) => run.tokens.output) / withBreakdown.length : null,
      avgCachedTokens: withBreakdown.length ? sum(withBreakdown, (run) => run.tokens.cached) / withBreakdown.length : null,
      totalCostUSD: withCost.length ? totalCost : null,
      costPerSolvedUSD: withCost.length && successes.length ? totalCost / successes.length : null,
      tokensPerSolved: withTokens.length && successes.length ? totalTokensSum / successes.length : null,
      medianWallMs: median(completed.map((run) => run.wallMs)),
      coverage: {
        tokens: runs.length ? withTokens.length / runs.length : 0,
        cost: runs.length ? withCost.length / runs.length : 0,
        approvals: runs.length ? withApprovals.length / runs.length : 0
      }
    };
  }).sort((a, b) => b.successRate - a.successRate || (a.tokensPerSolved ?? Infinity) - (b.tokensPerSolved ?? Infinity));
}
