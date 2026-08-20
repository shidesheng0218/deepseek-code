/**
 * OpenCode 驱动器：`opencode run` headless 模式。
 * OpenCode 的 token/approval 度量在 headless 输出中不稳定，v0 只记录
 * 完成状态与墙钟；度量缺口在报告中以覆盖率列明示。
 */
import { writeFileSync } from 'node:fs';
import { spawnLines, which } from './util.mjs';

export default {
  name: 'opencode',

  async detect() {
    return which('opencode') ? { ok: true } : { ok: false, reason: 'opencode CLI 未安装' };
  },

  async run({ task, workDir, model, env, timeoutMs, transcriptFile }) {
    const args = ['run', task.prompt];
    if (model?.model) args.push('--model', model.model);
    args.push(...(model?.extraArgs ?? []));
    const lines = [];
    const outcome = await spawnLines('opencode', args, { cwd: workDir, env: env ?? process.env, timeoutMs }, (line) => lines.push(line));
    writeFileSync(transcriptFile, JSON.stringify({ harness: 'opencode', taskID: task.id, args, output: lines.join('\n'), stderr: outcome.stderr }, null, 2));

    if (outcome.timedOut) return { status: 'error', error: `超时（${timeoutMs}ms）` };
    if (outcome.exitCode !== 0) return { status: 'error', error: `退出码 ${outcome.exitCode}：${outcome.stderr.slice(-300)}` };
    return { status: 'completed', approvals: null, tokens: null, costUSD: null };
  }
};
