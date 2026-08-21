#!/usr/bin/env node
/**
 * 代码图谱 token 消耗对比（Phase 2 验收 #3）
 *
 * 目标：重构任务上下文 token 消耗 -40%
 *
 * 测试策略：
 * 1. 准备一个真实重构任务："重命名 PolicyEngine 为 ExecPolicyEngine"
 * 2. 方案 A（传统路径）：read_file + grep，手动找所有引用
 * 3. 方案 B（图谱路径）：graph_symbol_card + graph_who_calls
 * 4. 统计两者的输入 token 消耗（通过 usage_recorded 事件）
 */

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, cpSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const sidecarEntry = join(root, 'apps', 'deepseek-agent-runtime', 'src', 'main.ts');
const bun = join(root, 'node_modules', '@oven', 'bun-darwin-aarch64', 'bin', 'bun');

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
    const id = `graph-${++counter}`;
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

function calculateTokens(events) {
  const usageEvents = events.filter((e) => e.type === 'usage_recorded');
  let inputTokens = 0;
  let outputTokens = 0;
  for (const event of usageEvents) {
    inputTokens += event.payload?.inputTokens ?? 0;
    outputTokens += event.payload?.outputTokens ?? 0;
  }
  return { inputTokens, outputTokens, total: inputTokens + outputTokens };
}

console.log(`代码图谱 Token 消耗对比测试`);
console.log(`API: ${DEEPSEEK_BASE_URL}`);
console.log(`Model: ${DEEPSEEK_MODEL}\n`);

const sessionRoot = join(tmpdir(), `deepseek-graph-${Date.now()}`);
mkdirSync(sessionRoot, { recursive: true });

// 准备测试项目（复制 src/core 到临时目录）
const testProjectPath = join(sessionRoot, 'test-project');
cpSync(join(root, 'src', 'core'), join(testProjectPath, 'src', 'core'), { recursive: true });

const sidecar = startSidecar(sessionRoot);

// 先索引代码图谱（只需一次）
console.log('索引代码图谱...');
await sidecar.send('session.run', {
  sessionID: 'index-graph',
  projectPath: testProjectPath,
  prompt: 'Index the codebase with graph_module_map for src/core directory',
  baseURL: DEEPSEEK_BASE_URL,
  apiKey: DEEPSEEK_API_KEY,
  model: DEEPSEEK_MODEL,
  protocol: 'openai-compatible',
  mode: 'auto'
}, 120_000);
console.log('索引完成\n');

// 方案 A：传统路径（read_file + grep）
console.log('='.repeat(60));
console.log('方案 A：传统路径（read_file + grep）\n');

const traditionalSessionID = 'traditional-refactor';
try {
  await sidecar.send('session.run', {
    sessionID: traditionalSessionID,
    projectPath: testProjectPath,
    prompt: 'Find all references to PolicyEngine class in the codebase. Use read_file and search_workspace to locate all usages.',
    baseURL: DEEPSEEK_BASE_URL,
    apiKey: DEEPSEEK_API_KEY,
    model: DEEPSEEK_MODEL,
    protocol: 'openai-compatible',
    mode: 'auto'
  });

  const traditionalEvents = readSessionEvents(sessionRoot, traditionalSessionID);
  const traditionalTokens = calculateTokens(traditionalEvents);

  console.log(`输入 tokens: ${traditionalTokens.inputTokens}`);
  console.log(`输出 tokens: ${traditionalTokens.outputTokens}`);
  console.log(`总计: ${traditionalTokens.total}\n`);

  // 方案 B：图谱路径（graph_symbol_card + graph_who_calls）
  console.log('='.repeat(60));
  console.log('方案 B：图谱路径（graph_symbol_card + graph_who_calls）\n');

  const graphSessionID = 'graph-refactor';
  await sidecar.send('session.run', {
    sessionID: graphSessionID,
    projectPath: testProjectPath,
    prompt: 'Find all references to PolicyEngine class using graph_symbol_card and graph_who_calls tools.',
    baseURL: DEEPSEEK_BASE_URL,
    apiKey: DEEPSEEK_API_KEY,
    model: DEEPSEEK_MODEL,
    protocol: 'openai-compatible',
    mode: 'auto'
  });

  const graphEvents = readSessionEvents(sessionRoot, graphSessionID);
  const graphTokens = calculateTokens(graphEvents);

  console.log(`输入 tokens: ${graphTokens.inputTokens}`);
  console.log(`输出 tokens: ${graphTokens.outputTokens}`);
  console.log(`总计: ${graphTokens.total}\n`);

  // 对比分析
  console.log('='.repeat(60));
  console.log('对比分析\n');

  const savings = ((traditionalTokens.total - graphTokens.total) / traditionalTokens.total * 100).toFixed(1);

  console.log(`传统路径总 tokens: ${traditionalTokens.total}`);
  console.log(`图谱路径总 tokens: ${graphTokens.total}`);
  console.log(`节省: ${savings}%\n`);

  const passed = parseFloat(savings) >= 40;
  console.log(passed ? '✅ Phase 2 验收通过（目标 -40%）' : `❌ Phase 2 验收未达标（目标 -40%，实际 ${savings}%）`);

  // 输出详细结果
  const results = {
    traditional: {
      inputTokens: traditionalTokens.inputTokens,
      outputTokens: traditionalTokens.outputTokens,
      total: traditionalTokens.total
    },
    graph: {
      inputTokens: graphTokens.inputTokens,
      outputTokens: graphTokens.outputTokens,
      total: graphTokens.total
    },
    savings: parseFloat(savings)
  };

  writeFileSync(join(root, 'benchmarks', 'graph-token-comparison.json'), JSON.stringify(results, null, 2));
  console.log(`\n详细结果已写入: benchmarks/graph-token-comparison.json`);

  sidecar.child.kill('SIGTERM');
  rmSync(sessionRoot, { recursive: true, force: true });

  process.exit(passed ? 0 : 1);

} catch (error) {
  console.error(`测试失败: ${error instanceof Error ? error.message : String(error)}`);
  sidecar.child.kill('SIGTERM');
  rmSync(sessionRoot, { recursive: true, force: true });
  process.exit(1);
}
