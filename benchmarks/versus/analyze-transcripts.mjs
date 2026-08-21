#!/usr/bin/env node
/**
 * 从 transcripts 目录重建 versus 统计报告（当 results.jsonl 为空或不可用时）
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const transcriptsDir = process.argv[2];
if (!transcriptsDir || !existsSync(transcriptsDir)) {
  console.error('用法：node analyze-transcripts.mjs <transcripts-dir>');
  process.exit(1);
}

const files = readdirSync(transcriptsDir).filter(f => f.endsWith('.json'));
const results = [];

for (const file of files) {
  const match = file.match(/^(\w+)-(.+)-r(\d+)\.json$/);
  if (!match) continue;

  const [, harness, taskID, runIndex] = match;
  const content = JSON.parse(readFileSync(join(transcriptsDir, file), 'utf8'));

  // deepseek: events-based
  if (harness === 'deepseek' && content.events && content.events.length > 0) {
    const usageEvents = content.events.filter(e => e.type === 'usage_recorded');
    const totalInput = usageEvents.reduce((sum, e) => sum + (e.inputTokens || 0), 0);
    const totalOutput = usageEvents.reduce((sum, e) => sum + (e.outputTokens || 0), 0);
    const approvals = content.events.filter(e => e.type === 'approval_required').length;

    results.push({
      harness,
      taskID,
      runIndex: parseInt(runIndex, 10),
      totalTokens: totalInput + totalOutput,
      inputTokens: totalInput,
      outputTokens: totalOutput,
      approvals,
      eventsCount: content.events.length
    });
  }

  // claude-code: frames-based
  if (harness === 'claude-code' && content.frames && content.frames.length > 0) {
    // extract token/approval info from frames if available
    results.push({
      harness,
      taskID,
      runIndex: parseInt(runIndex, 10),
      framesCount: content.frames.length
    });
  }
}

// Group by harness
const byHarness = {};
for (const r of results) {
  if (!byHarness[r.harness]) byHarness[r.harness] = [];
  byHarness[r.harness].push(r);
}

console.log('## Transcript 统计\n');
for (const [harness, runs] of Object.entries(byHarness)) {
  console.log(`### ${harness}`);
  console.log(`- 有效运行：${runs.length}`);

  if (harness === 'deepseek') {
    const avgInput = Math.round(runs.reduce((s, r) => s + r.inputTokens, 0) / runs.length);
    const avgOutput = Math.round(runs.reduce((s, r) => s + r.outputTokens, 0) / runs.length);
    const avgTotal = Math.round(runs.reduce((s, r) => s + r.totalTokens, 0) / runs.length);
    const avgApprovals = (runs.reduce((s, r) => s + r.approvals, 0) / runs.length).toFixed(1);

    console.log(`- 平均输入 token：${avgInput.toLocaleString()}`);
    console.log(`- 平均输出 token：${avgOutput.toLocaleString()}`);
    console.log(`- 平均总 token：${avgTotal.toLocaleString()}`);
    console.log(`- 平均审批次数：${avgApprovals}`);

    // Token 分布
    const sorted = runs.map(r => r.totalTokens).sort((a, b) => a - b);
    const p50 = sorted[Math.floor(sorted.length * 0.5)];
    const p95 = sorted[Math.floor(sorted.length * 0.95)];
    console.log(`- Token 中位数：${p50.toLocaleString()}`);
    console.log(`- Token P95：${p95.toLocaleString()}`);

    // 按任务统计成功率（需要 verify 结果，这里先占位）
    const tasks = new Set(runs.map(r => r.taskID));
    console.log(`- 覆盖任务数：${tasks.size}`);
  }

  console.log('');
}

// 输出 JSON 供后续处理
console.log('\n---\n');
console.log(JSON.stringify(results, null, 2));
