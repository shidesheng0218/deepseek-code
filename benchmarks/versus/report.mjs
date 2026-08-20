/**
 * versus 报告生成（纯函数）：Markdown 对照表 + JSON 摘要。
 * 报告纪律（来自 FULL_SPECTRUM_DOMINANCE.md）：
 * - 度量缺口（tokens/cost/approvals 覆盖率）必须展示，不允许悄悄缺席；
 * - 每个 harness 使用的模型如实标注，跨模型行不参与"同模型"结论；
 * - 页脚注明测量方法，让第三方可以复跑。
 */

function formatNumber(value, digits = 0) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  return value.toLocaleString('en-US', { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

function formatUSD(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—';
  return `$${value.toFixed(value < 0.1 ? 4 : 2)}`;
}

function formatPercent(value) {
  return `${Math.round((value ?? 0) * 100)}%`;
}

function formatWall(ms) {
  if (ms === null || ms === undefined) return '—';
  return ms >= 60_000 ? `${(ms / 60_000).toFixed(1)}min` : `${(ms / 1000).toFixed(1)}s`;
}

export function renderMarkdown({ stamp, modelLabel, stats, results, tasks }) {
  const lines = [];
  lines.push(`# DeepSeek Code versus 对照报告`, ``);
  lines.push(`- 运行时间：${stamp}`);
  lines.push(`- 模型口径：${modelLabel ?? '未声明（检查 versus.config.json）'}`);
  lines.push(`- 任务数：${tasks.length}，运行总数：${results.length}`);
  lines.push(`- 成功判定：harness 结束后在隔离工作区执行任务的 verify 命令（退出码为 0）；harness 自述完成不算数。`);
  lines.push(``);
  lines.push(`| Harness | 成功率 | 平均审批 | 平均输入 Tok | 平均输出 Tok | 均摊成本/成功 | 均摊 Tok/成功 | 中位耗时 | 度量覆盖 |`);
  lines.push(`| --- | --- | --- | --- | --- | --- | --- | --- | --- |`);
  for (const row of stats) {
    const coverage = `tok ${formatPercent(row.coverage.tokens)} · cost ${formatPercent(row.coverage.cost)} · appr ${formatPercent(row.coverage.approvals)}`;
    lines.push(`| ${row.harness} | ${row.successes}/${row.runs}（${formatPercent(row.successRate)}） | ${formatNumber(row.avgApprovals, 1)} | ${formatNumber(row.avgInputTokens)} | ${formatNumber(row.avgOutputTokens)} | ${formatUSD(row.costPerSolvedUSD)} | ${formatNumber(row.tokensPerSolved)} | ${formatWall(row.medianWallMs)} | ${coverage} |`);
  }
  lines.push(``);
  const failed = results.filter((result) => !result.success);
  if (failed.length) {
    lines.push(`## 未成功运行`, ``);
    for (const result of failed) {
      const why = result.status === 'error'
        ? (result.error ?? '未知错误')
        : result.verify ? `verify 退出码 ${result.verify.exitCode}${result.verify.timedOut ? '（超时）' : ''}` : '未执行 verify';
      lines.push(`- ✗ ${result.harness} · ${result.taskID} · run ${result.runIndex}：${why}`);
    }
    lines.push(``);
  }
  lines.push(`## 测量方法`, ``);
  lines.push(`- 每个（harness × 任务 × 轮次）在独立的临时工作区运行，语料项目先 git init 再交予 harness，互不污染。`);
  lines.push(`- 各 harness 以 headless 模式驱动：deepseek 走 sidecar session.run；claude-code 走 claude -p --output-format json；codex 走 codex exec --json；opencode 走 opencode run。`);
  lines.push(`- 审批口径：deepseek 计 approval_required 事件；claude-code 计 permission_denials；其余按可得性标注覆盖率为 0 时不参与审批比较。`);
  lines.push(`- 成本口径：driver 上报的 costUSD 优先；否则按 versus.config.json 的 pricePerMToken 由 token 换算；皆无则为 "—"。`);
  lines.push(`- 复跑：node benchmarks/versus/run.mjs（同题语料与驱动器全部开源在本仓库 benchmarks/versus/）。`);
  return `${lines.join('\n')}\n`;
}

export function buildReportJson({ stamp, modelLabel, stats, results }) {
  return { schemaVersion: 1, stamp, modelLabel: modelLabel ?? null, stats, results };
}
