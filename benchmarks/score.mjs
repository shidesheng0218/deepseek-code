#!/usr/bin/env node
/**
 * 汇总最近一次 benchmark 运行：通过率、审批次数、token 成本。
 * 与 Claude Code 对照时，双方各跑同题语料后比较本输出。
 */
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const resultsDir = join(root, 'benchmarks', 'results');

if (!existsSync(resultsDir)) { console.error('No benchmark results yet'); process.exit(2); }
const runs = readdirSync(resultsDir).sort();
const latest = runs.at(-1);
if (!latest) { console.error('No benchmark results yet'); process.exit(2); }
const runDir = join(resultsDir, latest);
const summary = JSON.parse(readFileSync(join(runDir, 'summary.json'), 'utf8'));

let approvals = 0;
let inputTokens = 0;
let outputTokens = 0;
let cachedTokens = 0;
for (const item of summary.summary) {
  const file = join(runDir, `${item.id}.json`);
  if (!existsSync(file)) continue;
  const { events } = JSON.parse(readFileSync(file, 'utf8'));
  approvals += events.filter((event) => event.type === 'approval_required').length;
  for (const event of events) {
    if (event.type !== 'usage_recorded') continue;
    inputTokens += event.inputTokens ?? 0;
    outputTokens += event.outputTokens ?? 0;
    cachedTokens += event.cachedInputTokens ?? 0;
  }
}

console.log(`Run: ${latest} (${summary.real ? 'real provider' : 'mock provider'})`);
console.log(`Success rate: ${summary.passed}/${summary.total} (${Math.round((summary.passed / summary.total) * 100)}%)`);
console.log(`Approvals requested: ${approvals}`);
console.log(`Tokens: input ${inputTokens} (cached ${cachedTokens}), output ${outputTokens}`);
const failed = summary.summary.filter((item) => !item.ok);
if (failed.length) {
  console.log('\nFailed fixtures:');
  for (const item of failed) console.log(`  ✗ ${item.id}: ${(item.failures ?? []).join('; ')}`);
}
