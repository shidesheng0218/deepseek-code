#!/usr/bin/env node
/**
 * Seeded-Bug 语料测试（NEXT_GEN_ARCHITECTURE Phase 1 验收）
 *
 * 目标：量化 Verifier Worker 的拦截率 vs Codex 自评的漏检率
 * 验收标准：Verifier 拦截率 ≥ 70%，误拦率 ≤ 10%
 *
 * Phase 2 v2：接真实 Provider，实际运行主 Agent 修复
 */

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const sidecarEntry = join(root, 'apps', 'deepseek-agent-runtime', 'src', 'main.ts');
const bun = join(root, 'node_modules', '@oven', 'bun-darwin-aarch64', 'bin', 'bun');
const bugsDir = join(root, 'benchmarks', 'seeded-bugs');

// 从环境变量读取真实 API 配置
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY || '';
const DEEPSEEK_BASE_URL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com/v1';
const DEEPSEEK_MODEL = process.env.DEEPSEEK_MODEL || 'deepseek-chat';

if (!DEEPSEEK_API_KEY) {
  console.error('❌ 需要设置 DEEPSEEK_API_KEY 环境变量');
  console.error('   export DEEPSEEK_API_KEY=sk-...');
  process.exit(1);
}

function startSidecar(sessionRoot) {
  const child = spawn(bun, [sidecarEntry, '--stdio'], {
    cwd: root,
    env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  const waiters = new Map();
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let frame;
      try { frame = JSON.parse(line); } catch { continue; }
      if (frame.type === 'response' && waiters.has(frame.id)) {
        waiters.get(frame.id)(frame);
        waiters.delete(frame.id);
      }
    }
  });
  let counter = 0;
  const send = (method, params, timeoutMs = 120_000) => new Promise((resolve, reject) => {
    const id = `seeded-${++counter}`;
    const timer = setTimeout(() => { waiters.delete(id); reject(new Error(`${method} timed out`)); }, timeoutMs);
    waiters.set(id, (frame) => { clearTimeout(timer); resolve(frame); });
    child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
  });
  return { child, send };
}

function readSessionEvents(sessionRoot, sessionID) {
  const file = join(sessionRoot, `${sessionID}.jsonl`);
  try {
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}

function extractVerifierVerdict(events) {
  const verdicts = events.filter((event) => event.type === 'verifier_verdict');
  if (verdicts.length === 0) return null;
  const latest = verdicts[verdicts.length - 1];
  return {
    state: latest.payload?.state,
    counterEvidence: latest.payload?.counterEvidence ?? [],
    summary: latest.payload?.summary ?? ''
  };
}

// 加载所有 seeded-bug 案例
const bugFiles = readdirSync(bugsDir).filter((name) => name.endsWith('.json'));
const bugs = bugFiles.map((name) => {
  const content = readFileSync(join(bugsDir, name), 'utf8');
  return { id: name.replace('.json', ''), ...JSON.parse(content) };
});

if (bugs.length === 0) {
  console.error('❌ 未找到 seeded-bug 案例（需要 ≥20 个）');
  process.exit(1);
}

console.log(`加载了 ${bugs.length} 个 seeded-bug 案例`);
console.log(`API: ${DEEPSEEK_BASE_URL}`);
console.log(`Model: ${DEEPSEEK_MODEL}\n`);

const sessionRoot = join(tmpdir(), `deepseek-seeded-${Date.now()}`);
mkdirSync(sessionRoot, { recursive: true });
const sidecar = startSidecar(sessionRoot);
const results = [];

for (const bug of bugs) {
  const sessionID = `seeded-${bug.id}`;
  console.log(`[${bug.id}] ${bug.description}`);

  // 1. 在临时目录创建缺陷代码
  const projectPath = join(sessionRoot, sessionID);
  mkdirSync(projectPath, { recursive: true });
  writeFileSync(join(projectPath, bug.file), bug.buggyCode);
  if (bug.testFile && bug.testCode) {
    writeFileSync(join(projectPath, bug.testFile), bug.testCode);
  }

  // 2. 运行 session.run 让主 Agent 修复（真实 Provider）
  try {
    const response = await sidecar.send('session.run', {
      sessionID,
      projectPath,
      prompt: bug.fixPrompt,
      baseURL: DEEPSEEK_BASE_URL,
      apiKey: DEEPSEEK_API_KEY,
      model: DEEPSEEK_MODEL,
      protocol: 'openai-compatible',
      mode: 'auto'
    }, 180_000); // 3 分钟超时

    const events = readSessionEvents(sessionRoot, sessionID);
    const verdict = extractVerifierVerdict(events);

    results.push({
      id: bug.id,
      description: bug.description,
      goldenTruth: bug.goldenTruth,
      verifierState: verdict?.state ?? 'missing',
      verifierSummary: verdict?.summary ?? '',
      agentStatus: response.result?.status ?? 'unknown'
    });

    console.log(`  Agent: ${response.result?.status ?? 'unknown'}`);
    console.log(`  Verifier: ${verdict?.state ?? 'missing'}`);
    if (verdict?.counterEvidence && verdict.counterEvidence.length > 0) {
      console.log(`  反驳: ${verdict.counterEvidence[0].slice(0, 80)}`);
    }
    console.log('');
  } catch (error) {
    results.push({
      id: bug.id,
      description: bug.description,
      goldenTruth: bug.goldenTruth,
      verifierState: 'error',
      verifierSummary: error instanceof Error ? error.message : String(error),
      agentStatus: 'error'
    });
    console.log(`  Error: ${error instanceof Error ? error.message : String(error)}\n`);
  }
}

sidecar.child.kill('SIGTERM');

// 3. 计算指标
const trueErrors = results.filter((r) => r.goldenTruth === 'buggy');
const trueCorrect = results.filter((r) => r.goldenTruth === 'correct');

const trueErrorsRefuted = results.filter((r) => r.goldenTruth === 'buggy' && r.verifierState === 'refuted');
const trueCorrectRefuted = results.filter((r) => r.goldenTruth === 'correct' && r.verifierState === 'refuted');
const trueErrorsPassed = results.filter((r) => r.goldenTruth === 'buggy' && r.verifierState === 'pass');

const interceptRate = trueErrors.length > 0 ? (trueErrorsRefuted.length / trueErrors.length * 100).toFixed(1) : 0;
const falsePositiveRate = trueCorrect.length > 0 ? (trueCorrectRefuted.length / trueCorrect.length * 100).toFixed(1) : 0;
const missRate = trueErrors.length > 0 ? (trueErrorsPassed.length / trueErrors.length * 100).toFixed(1) : 0;

console.log('='.repeat(60));
console.log('Seeded-Bug 测试结果\n');
console.log(`总案例数: ${results.length}`);
console.log(`真实错误: ${trueErrors.length} | 真实正确: ${trueCorrect.length}\n`);
console.log(`Verifier 拦截率: ${interceptRate}% (目标 ≥70%)`);
console.log(`Verifier 误拦率: ${falsePositiveRate}% (目标 ≤10%)`);
console.log(`Verifier 漏检率: ${missRate}%\n`);

const passed_threshold = parseFloat(interceptRate) >= 70 && parseFloat(falsePositiveRate) <= 10;
console.log(passed_threshold ? '✅ Phase 1 验收通过' : '❌ Phase 1 验收未达标');

// 输出详细结果
writeFileSync(join(bugsDir, 'results.json'), JSON.stringify(results, null, 2));
console.log(`\n详细结果已写入: benchmarks/seeded-bugs/results.json`);

// 清理临时目录
try { rmSync(sessionRoot, { recursive: true, force: true }); } catch {}

process.exit(passed_threshold ? 0 : 1);
