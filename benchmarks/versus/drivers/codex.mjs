/**
 * Codex CLI 驱动器：`codex exec --json` 非交互模式。
 *
 * Codex 只支持 OpenAI 系模型，通常无法与 Anthropic 系做同模型对照；
 * 报告中会按 versus.config.json 里登记的 model 如实标注口径。
 * JSONL 事件结构随版本变化，解析全部防御式：抓不到 usage/approval 即记 null，
 * 绝不让解析失败误判为任务失败。
 */
import { writeFileSync } from 'node:fs';
import { spawnLines, which } from './util.mjs';

function readUsage(event) {
  const candidates = [event?.usage, event?.payload?.usage, event?.msg?.usage, event?.item?.usage];
  for (const usage of candidates) {
    if (usage && typeof usage === 'object' && ('input_tokens' in usage || 'output_tokens' in usage)) return usage;
  }
  return null;
}

export default {
  name: 'codex',

  async detect() {
    return which('codex') ? { ok: true } : { ok: false, reason: 'codex CLI 未安装' };
  },

  async run({ task, workDir, model, env, timeoutMs, transcriptFile }) {
    const args = ['exec', '--json', ...(model?.extraArgs ?? ['--full-auto'])];
    if (model?.model) args.push('--model', model.model);
    args.push(task.prompt);
    const events = [];
    const outcome = await spawnLines('codex', args, { cwd: workDir, env: env ?? process.env, timeoutMs }, (line) => {
      try { events.push(JSON.parse(line)); } catch { /* 非 JSON 行忽略 */ }
    });
    writeFileSync(transcriptFile, JSON.stringify({ harness: 'codex', taskID: task.id, args, events, stderr: outcome.stderr }, null, 2));

    if (outcome.timedOut) return { status: 'error', error: `超时（${timeoutMs}ms）` };
    if (outcome.exitCode !== 0 && events.length === 0) return { status: 'error', error: `退出码 ${outcome.exitCode}：${outcome.stderr.slice(-300)}` };

    let tokens = null;
    for (const event of events) {
      const usage = readUsage(event);
      if (usage) tokens = { input: Number(usage.input_tokens ?? 0), output: Number(usage.output_tokens ?? 0), cached: Number(usage.cached_input_tokens ?? usage.cached_tokens ?? 0) };
    }
    const typeOf = (event) => String(event?.type ?? event?.msg?.type ?? '');
    return {
      status: 'completed',
      approvals: events.filter((event) => typeOf(event).includes('approval')).length || null,
      tokens,
      costUSD: null
    };
  }
};
