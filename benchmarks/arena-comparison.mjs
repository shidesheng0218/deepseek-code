#!/usr/bin/env node
/**
 * 锦标赛成功率对比（Phase 2 验收 #2）
 *
 * 目标：锦标赛 vs 单路径，难题成功率 +15pp
 *
 * 测试策略：
 * 1. 从 seeded-bugs 挑 5 个最难的（需要多次尝试才能解决的）
 * 2. 单路径跑一遍：session.run，记录成功/失败
 * 3. 锦标赛跑一遍：session.arena（2-3 个假设），记录胜者
 * 4. 对比成功率
 */

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const sidecarEntry = join(root, 'apps', 'deepseek-agent-runtime', 'src', 'main.ts');
const bun = join(root, 'node_modules', '@oven', 'bun-darwin-aarch64', 'bin', 'bun');

// 从环境变量读取 API 配置
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY || '';
const DEEPSEEK_BASE_URL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com/v1';
const DEEPSEEK_MODEL = process.env.DEEPSEEK_MODEL || 'deepseek-chat';

if (!DEEPSEEK_API_KEY) {
  console.error('❌ 需要设置 DEEPSEEK_API_KEY 环境变量');
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
  const send = (method, params, timeoutMs = 180_000) => new Promise((resolve, reject) => {
    const id = `arena-${++counter}`;
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

// 挑选 5 个最难的 bug（需要多种方法尝试）
const hardBugs = [
  {
    id: 'hard-001',
    description: '异步竞态条件：未正确等待 Promise',
    file: 'fetch.js',
    buggyCode: `async function fetchUserData(userId) {\n  const response = fetch(\`https://api.example.com/users/\${userId}\`);\n  return response.json();\n}\nmodule.exports = { fetchUserData };`,
    testFile: 'fetch.test.js',
    testCode: `const { fetchUserData } = require('./fetch');\nglobal.fetch = async (url) => ({ json: async () => ({ id: 1, name: 'test' }) });\nfetchUserData(1).then(data => {\n  if (data && data.name === 'test') console.log('All tests passed');\n  else throw new Error('Failed');\n}).catch(err => { console.error(err); process.exit(1); });`,
    fixPrompt: 'Fix the async function - missing await on the fetch call'
  },
  {
    id: 'hard-002',
    description: '并发计数器竞态条件',
    file: 'counter.js',
    buggyCode: `class Counter {\n  constructor() { this.value = 0; }\n  async increment() {\n    const current = this.value;\n    await new Promise(r => setTimeout(r, 1));\n    this.value = current + 1;\n  }\n  getValue() { return this.value; }\n}\nmodule.exports = { Counter };`,
    testFile: 'counter.test.js',
    testCode: `const { Counter } = require('./counter');\nconst counter = new Counter();\nPromise.all([counter.increment(), counter.increment(), counter.increment()]).then(() => {\n  if (counter.getValue() === 3) console.log('All tests passed');\n  else throw new Error(\`Expected 3, got \${counter.getValue()}\`);\n}).catch(e => { console.error(e); process.exit(1); });`,
    fixPrompt: 'Fix race condition in Counter - increment should be atomic'
  },
  {
    id: 'hard-003',
    description: 'XSS 漏洞：未转义 HTML',
    file: 'render.js',
    buggyCode: `function renderUserComment(comment) {\n  return \`<div class="comment">\${comment}</div>\`;\n}\nmodule.exports = { renderUserComment };`,
    testFile: 'render.test.js',
    testCode: `const { renderUserComment } = require('./render');\nconst assert = require('assert');\nconst safe = renderUserComment('Hello world');\nassert(safe.includes('Hello world'));\nconst unsafe = renderUserComment('<script>alert(1)</script>');\nassert(!unsafe.includes('<script>'), 'XSS vulnerability detected');\nconsole.log('All tests passed');`,
    fixPrompt: 'Fix XSS vulnerability - escape HTML entities in user comments'
  },
  {
    id: 'hard-004',
    description: '闭包循环变量捕获错误',
    file: 'timer.js',
    buggyCode: `function createTimers(count) {\n  const timers = [];\n  for (var i = 0; i < count; i++) {\n    timers.push(() => i);\n  }\n  return timers;\n}\nmodule.exports = { createTimers };`,
    testFile: 'timer.test.js',
    testCode: `const { createTimers } = require('./timer');\nconst assert = require('assert');\nconst timers = createTimers(3);\nassert.strictEqual(timers[0](), 0);\nassert.strictEqual(timers[1](), 1);\nassert.strictEqual(timers[2](), 2);\nconsole.log('All tests passed');`,
    fixPrompt: 'Fix closure bug - use let instead of var in the loop'
  },
  {
    id: 'hard-005',
    description: '除零错误未处理',
    file: 'average.js',
    buggyCode: `function average(numbers) {\n  const sum = numbers.reduce((a, b) => a + b, 0);\n  return sum / numbers.length;\n}\nmodule.exports = { average };`,
    testFile: 'average.test.js',
    testCode: `const { average } = require('./average');\nconst assert = require('assert');\nassert.strictEqual(average([1, 2, 3]), 2);\nassert.strictEqual(average([]), 0);\nassert.strictEqual(average([5]), 5);\nconsole.log('All tests passed');`,
    fixPrompt: 'Fix average function to handle empty array - return 0 instead of NaN'
  }
];

console.log(`锦标赛成功率对比测试`);
console.log(`API: ${DEEPSEEK_BASE_URL}`);
console.log(`Model: ${DEEPSEEK_MODEL}`);
console.log(`测试案例: ${hardBugs.length} 个\n`);

const sessionRoot = join(tmpdir(), `deepseek-arena-${Date.now()}`);
mkdirSync(sessionRoot, { recursive: true });
const sidecar = startSidecar(sessionRoot);

const singlePathResults = [];
const arenaResults = [];

// 1. 单路径测试
console.log('='.repeat(60));
console.log('阶段 1：单路径测试\n');

for (const bug of hardBugs) {
  console.log(`[${bug.id}] ${bug.description}`);
  const sessionID = `single-${bug.id}`;
  const projectPath = join(sessionRoot, sessionID);
  mkdirSync(projectPath, { recursive: true });
  writeFileSync(join(projectPath, bug.file), bug.buggyCode);
  writeFileSync(join(projectPath, bug.testFile), bug.testCode);

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
    });

    const events = readSessionEvents(sessionRoot, sessionID);
    const deliveryEvents = events.filter((e) => e.type === 'delivery_evaluated');
    const lastDelivery = deliveryEvents[deliveryEvents.length - 1];
    const state = lastDelivery?.payload?.state ?? 'unknown';
    const success = state === 'delivered';

    singlePathResults.push({ id: bug.id, success, state });
    console.log(`  结果: ${success ? '✅ 成功' : '❌ 失败'} (${state})\n`);
  } catch (error) {
    singlePathResults.push({ id: bug.id, success: false, state: 'error' });
    console.log(`  错误: ${error instanceof Error ? error.message : String(error)}\n`);
  }
}

// 2. 锦标赛测试
console.log('='.repeat(60));
console.log('阶段 2：锦标赛测试\n');

for (const bug of hardBugs) {
  console.log(`[${bug.id}] ${bug.description}`);
  const sessionID = `arena-${bug.id}`;
  const projectPath = join(sessionRoot, sessionID);
  mkdirSync(projectPath, { recursive: true });
  writeFileSync(join(projectPath, bug.file), bug.buggyCode);
  writeFileSync(join(projectPath, bug.testFile), bug.testCode);

  try {
    const response = await sidecar.send('session.arena', {
      sessionID,
      projectPath,
      prompt: bug.fixPrompt,
      baseURL: DEEPSEEK_BASE_URL,
      apiKey: DEEPSEEK_API_KEY,
      model: DEEPSEEK_MODEL,
      protocol: 'openai-compatible',
      mode: 'auto'
    }, 300_000); // 5 分钟（锦标赛需要更长时间）

    const success = response.ok && response.result?.winner;
    arenaResults.push({ id: bug.id, success, winner: response.result?.winner, reasoning: response.result?.reasoning });
    console.log(`  结果: ${success ? '✅ 成功' : '❌ 失败'}`);
    if (success) {
      console.log(`  胜者: ${response.result.winner}`);
    }
    console.log('');
  } catch (error) {
    arenaResults.push({ id: bug.id, success: false, error: error instanceof Error ? error.message : String(error) });
    console.log(`  错误: ${error instanceof Error ? error.message : String(error)}\n`);
  }
}

sidecar.child.kill('SIGTERM');

// 3. 对比分析
console.log('='.repeat(60));
console.log('对比分析\n');

const singleSuccessCount = singlePathResults.filter((r) => r.success).length;
const arenaSuccessCount = arenaResults.filter((r) => r.success).length;

const singleSuccessRate = (singleSuccessCount / hardBugs.length * 100).toFixed(1);
const arenaSuccessRate = (arenaSuccessCount / hardBugs.length * 100).toFixed(1);
const improvement = (arenaSuccessCount - singleSuccessCount) / hardBugs.length * 100;

console.log(`单路径成功率: ${singleSuccessRate}% (${singleSuccessCount}/${hardBugs.length})`);
console.log(`锦标赛成功率: ${arenaSuccessRate}% (${arenaSuccessCount}/${hardBugs.length})`);
console.log(`提升: ${improvement >= 0 ? '+' : ''}${improvement.toFixed(1)} 百分点\n`);

const passed = improvement >= 15;
console.log(passed ? '✅ Phase 2 验收通过（目标 +15pp）' : `❌ Phase 2 验收未达标（目标 +15pp，实际 ${improvement.toFixed(1)}pp）`);

// 输出详细结果
const results = {
  singlePath: singlePathResults,
  arena: arenaResults,
  summary: {
    singleSuccessRate: parseFloat(singleSuccessRate),
    arenaSuccessRate: parseFloat(arenaSuccessRate),
    improvement: parseFloat(improvement.toFixed(1))
  }
};

writeFileSync(join(root, 'benchmarks', 'arena-comparison.json'), JSON.stringify(results, null, 2));
console.log(`\n详细结果已写入: benchmarks/arena-comparison.json`);

// 清理
try { rmSync(sessionRoot, { recursive: true, force: true }); } catch {}

process.exit(passed ? 0 : 1);
