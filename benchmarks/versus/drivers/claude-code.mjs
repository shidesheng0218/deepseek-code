/**
 * Claude Code 驱动器：`claude -p --output-format json` headless 模式。
 *
 * 公平性约定：
 * - --permission-mode acceptEdits 对应我们的 accept_edits/auto 自主档；
 *   审批次数用 permission_denials 数组长度近似（headless 无法交互审批，
 *   被拒绝的工具会计入并在报告中注明口径差异）。
 * - 模型由 versus.config.json → harnesses["claude-code"].model 指定，
 *   同模型纪律要求它与 deepseek.model 指向同一底层模型。
 * 度量来源：total_cost_usd / usage / permission_denials（解析失败则降级为 null）。
 */
import { writeFileSync } from 'node:fs';
import { spawnLines, which } from './util.mjs';

export default {
  name: 'claude-code',

  async detect() {
    return which('claude') ? { ok: true } : { ok: false, reason: 'claude CLI 未安装（npm i -g @anthropic-ai/claude-code）' };
  },

  async run({ task, workDir, model, env, timeoutMs, transcriptFile }) {
    const args = ['-p', task.prompt, '--output-format', 'json'];
    if (model?.model) args.push('--model', model.model);
    args.push(...(model?.extraArgs ?? ['--permission-mode', 'acceptEdits']));
    const lines = [];
    const outcome = await spawnLines('claude', args, { cwd: workDir, env: env ?? process.env, timeoutMs }, (line) => lines.push(line));
    const raw = lines.join('\n');
    writeFileSync(transcriptFile, JSON.stringify({ harness: 'claude-code', taskID: task.id, args, raw, stderr: outcome.stderr }, null, 2));

    if (outcome.timedOut) return { status: 'error', error: `超时（${timeoutMs}ms）` };
    let parsed = null;
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      try { parsed = JSON.parse(lines[index]); break; } catch { /* 继续向前寻找 JSON 行 */ }
    }
    if (!parsed || typeof parsed !== 'object') {
      return outcome.exitCode === 0
        ? { status: 'completed', approvals: null, tokens: null, costUSD: null }
        : { status: 'error', error: `退出码 ${outcome.exitCode}：${outcome.stderr.slice(-300)}` };
    }
    if (parsed.is_error === true) return { status: 'error', error: parsed.result ?? parsed.error ?? 'claude 返回 is_error' };
    const usage = parsed.usage && typeof parsed.usage === 'object' ? parsed.usage : null;
    // claude 上报的 total_cost_usd 按其内部 Anthropic 价目表计算；
    // 指向第三方端点（如 Kimi）时该数字失真，trustReportedCost: false 将其置空。
    const reportedCost = typeof parsed.total_cost_usd === 'number' && model?.trustReportedCost !== false ? parsed.total_cost_usd : null;
    return {
      status: 'completed',
      approvals: Array.isArray(parsed.permission_denials) ? parsed.permission_denials.length : null,
      tokens: usage ? {
        input: Number(usage.input_tokens ?? 0),
        output: Number(usage.output_tokens ?? 0),
        cached: Number(usage.cache_read_input_tokens ?? 0) + Number(usage.cache_creation_input_tokens ?? 0)
      } : null,
      costUSD: reportedCost
    };
  }
};
