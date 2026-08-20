/**
 * Echo 驱动器：自检测试替身。不执行任何修复动作，
 * 用于 `run.mjs --self-test` 验证编排、验证与报告管线的正确性——
 * 对带 bug 的语料项目它必然验证失败（success=false），这正是断言点。
 */
import { writeFileSync } from 'node:fs';

export default {
  name: 'echo',

  async detect() { return { ok: true }; },

  async run({ task, transcriptFile }) {
    writeFileSync(transcriptFile, JSON.stringify({ harness: 'echo', taskID: task.id, note: '自检替身：未执行任何修改' }, null, 2));
    return { status: 'completed', approvals: 0, tokens: { input: 0, output: 0, cached: 0 }, costUSD: 0 };
  }
};
