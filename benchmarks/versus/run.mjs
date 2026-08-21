#!/usr/bin/env node
/**
 * bench:versus —— 同模型对照基准台（证据机）。
 *
 * 用法：
 *   node benchmarks/versus/run.mjs                      # 全部已安装 harness × 全部任务
 *   node benchmarks/versus/run.mjs --harness=deepseek,claude-code
 *   node benchmarks/versus/run.mjs --task=vs-001-cart-total --runs=3
 *   node benchmarks/versus/run.mjs --check-corpus       # 只校验语料完整性（离线）
 *   node benchmarks/versus/run.mjs --self-test          # echo 替身验证编排管线（离线）
 *
 * 产出：benchmarks/results/versus/<timestamp>/{results.jsonl,report.json,report.md,transcripts/}
 * 退出码：对照运行是度量不是门禁，恒为 0；--check-corpus / --self-test 为 0/1。
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { aggregate, normalizeResult } from './harvest.mjs';
import { buildReportJson, renderMarkdown } from './report.mjs';
import { ensureDir, gitInit, materializeProject, resolveEnv, runCommand, versusDir } from './drivers/util.mjs';
import deepseek from './drivers/deepseek.mjs';
import claudeCode from './drivers/claude-code.mjs';
import codex from './drivers/codex.mjs';
import opencode from './drivers/opencode.mjs';
import echo from './drivers/echo.mjs';

const DRIVERS = { deepseek, 'claude-code': claudeCode, codex, opencode, echo };
const resultsRoot = join(versusDir, '..', 'results', 'versus');

function parseArgs(argv) {
  const options = { harness: null, task: null, runs: 1, checkCorpus: false, selfTest: false, sign: false, resume: null };
  for (const arg of argv) {
    if (arg.startsWith('--harness=')) options.harness = arg.slice('--harness='.length).split(',').filter(Boolean);
    else if (arg.startsWith('--task=')) options.task = arg.slice('--task='.length).split(',').filter(Boolean);
    else if (arg.startsWith('--runs=')) options.runs = Math.max(1, Number.parseInt(arg.slice('--runs='.length), 10) || 1);
    else if (arg.startsWith('--resume=')) options.resume = arg.slice('--resume='.length);
    else if (arg === '--check-corpus') options.checkCorpus = true;
    else if (arg === '--self-test') options.selfTest = true;
    else if (arg === '--sign') options.sign = true;
    else if (arg === '--help' || arg === '-h') { printUsage(); process.exit(0); }
    else { console.error(`未知参数：${arg}`); printUsage(); process.exit(2); }
  }
  return options;
}

function printUsage() {
  console.log(`用法：node benchmarks/versus/run.mjs [--harness=a,b] [--task=id1,id2] [--runs=N] [--resume=timestamp] [--check-corpus] [--self-test] [--sign]`);
}

function loadCorpus() {
  const corpusDir = join(versusDir, 'corpus');
  return readdirSync(corpusDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => {
      const task = JSON.parse(readFileSync(join(corpusDir, name), 'utf8'));
      task.projectDir = join(corpusDir, task.project);
      return task;
    });
}

function loadConfig() {
  const path = process.env.VS_CONFIG ?? join(versusDir, 'versus.config.json');
  if (!existsSync(path)) return { modelLabel: null, harnesses: {} };
  return JSON.parse(readFileSync(path, 'utf8'));
}

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

/** 离线语料完整性校验：项目齐全、可 git init、verify 在原始状态下符合 pristineFails 预期。 */
async function checkCorpus(tasks) {
  let failures = 0;
  for (const task of tasks) {
    const problems = [];
    if (!existsSync(task.projectDir)) problems.push(`项目目录不存在：${task.projectDir}`);
    if (!task.verify?.command) problems.push('缺少 verify.command');
    if (problems.length === 0) {
      const workDir = materializeProject(task.projectDir);
      gitInit(workDir);
      const outcome = await runCommand(task.verify.command, workDir, 120_000);
      const pristinePasses = outcome.exitCode === (task.verify.expectExitCode ?? 0);
      if (task.expect?.pristineFails === true && pristinePasses) problems.push('pristineFails=true 但原始项目验证通过（bug 不真实）');
      if (task.expect?.pristineFails === false && !pristinePasses) problems.push(`pristineFails=false 但原始项目验证失败（退出码 ${outcome.exitCode}）`);
    }
    const ok = problems.length === 0;
    if (!ok) failures += 1;
    console.log(`${ok ? '✓' : '✗'} ${task.id}${ok ? '' : ` — ${problems.join('；')}`}`);
  }
  console.log(`\n${tasks.length - failures}/${tasks.length} 个语料任务通过完整性校验`);
  return failures === 0;
}

async function runMatrix({ tasks, harnessNames, config, runs, runDir }) {
  ensureDir(join(runDir, 'transcripts'));

  // Check existing transcripts to avoid reruns (only valid ones with content)
  const existingTranscripts = new Set();
  const transcriptsDir = join(runDir, 'transcripts');
  if (existsSync(transcriptsDir)) {
    const files = readdirSync(transcriptsDir);
    for (const file of files) {
      if (file.endsWith('.json')) {
        try {
          const content = JSON.parse(readFileSync(join(transcriptsDir, file), 'utf8'));
          const isComplete = transcriptCompleted(content);
          if (isComplete) {
            existingTranscripts.add(file);
          }
        } catch {}
      }
    }
    console.log(`○ 发现有效 transcript：${existingTranscripts.size} 个`);
  }

  const results = [];
  for (const name of harnessNames) {
    const driver = DRIVERS[name];
    const model = config.harnesses?.[name] ?? {};
    const resolved = resolveEnv(model);
    const detection = missingEnvDetection(resolved) ?? await driver.detect(model);
    if (!detection.ok) {
      console.log(`○ ${name}：跳过（${detection.reason}）`);
      for (const task of tasks) for (let runIndex = 1; runIndex <= runs; runIndex += 1) {
        results.push(baseResult(task, name, runIndex, { status: 'skipped', error: detection.reason }));
      }
      continue;
    }
    const env = { ...process.env, ...resolved.env };
    for (const task of tasks) {
      for (let runIndex = 1; runIndex <= runs; runIndex += 1) {
        const transcriptFile = `${name}-${task.id}-r${runIndex}.json`;
        if (existingTranscripts.has(transcriptFile)) {
          console.log(`⊙ ${name} · ${task.id} · run ${runIndex} — transcript 已存在，跳过`);
          continue;
        }
        const result = await runOne({ driver, name, task, runIndex, model, env, runDir });
        results.push(result);
        const mark = result.success ? '✓' : result.status === 'error' ? '✗' : '○';
        const detail = result.success
          ? `${result.wallMs}ms${result.totalTokens !== null ? ` · ${result.totalTokens} tok` : ''}`
          : (result.error ?? (result.verify ? `verify 退出码 ${result.verify.exitCode}` : ''));
        console.log(`${mark} ${name} · ${task.id} · run ${runIndex} — ${detail}`);
      }
    }
  }
  return results;
}

function transcriptCompleted(content) {
  if (content.events && content.events.length > 0) {
    return content.events.some((e) => e.type === 'terminal_completed' || e.type === 'completed');
  }
  if (content.frames && content.frames.length > 0) {
    return content.frames.some((f) => f.type === 'result' || f.subtype === 'success' || f.subtype === 'completed');
  }
  return false;
}

function baseResult(task, harness, runIndex, overrides) {
  return {
    taskID: task.id, harness, runIndex, startedAt: new Date().toISOString(), wallMs: 0,
    status: 'completed', error: null, verify: null, success: false,
    approvals: null, tokens: null, costUSD: null, transcriptFile: null, totalTokens: null,
    ...overrides
  };
}

function missingEnvDetection(resolved) {
  return resolved.missing.length ? { ok: false, reason: `环境变量 ${resolved.missing.join(', ')} 未设置（config env 引用）` } : null;
}

async function runOne({ driver, name, task, runIndex, model, env, runDir }) {
  const startedAt = new Date().toISOString();
  const started = Date.now();
  const workDir = materializeProject(task.projectDir);
  gitInit(workDir);
  const transcriptFile = join(runDir, 'transcripts', `${name}-${task.id}-r${runIndex}.json`);
  const timeoutMs = task.timeoutMs ?? 300_000;
  let outcome;
  try {
    outcome = await driver.run({ task, workDir, model, env, timeoutMs, transcriptFile });
  } catch (error) {
    outcome = { status: 'error', error: error instanceof Error ? error.message : String(error) };
  }
  const wallMs = Date.now() - started;

  let verify = null;
  let success = false;
  if (outcome.status === 'completed' && task.verify?.command) {
    const outcomeVerify = await runCommand(task.verify.command, workDir, 120_000);
    verify = { command: task.verify.command, exitCode: outcomeVerify.exitCode, timedOut: outcomeVerify.timedOut };
    success = outcomeVerify.exitCode === (task.verify.expectExitCode ?? 0);
  }
  return normalizeResult(baseResult(task, name, runIndex, {
    startedAt, wallMs,
    status: outcome.status,
    error: outcome.error ?? null,
    verify, success,
    approvals: outcome.approvals ?? null,
    tokens: outcome.tokens ?? null,
    costUSD: typeof outcome.costUSD === 'number' ? outcome.costUSD : null,
    transcriptFile
  }), model?.pricePerMToken ?? null);
}

function maybeSign(filePath, enabled) {
  if (!enabled) return;
  const key = process.env.VS_SIGNING_KEY ?? join(process.env.HOME ?? '.', '.tauri', 'deepseek-code.key');
  if (!existsSync(key)) { console.log(`○ 签名跳过：找不到密钥 ${key}`); return; }
  const result = spawnSync('minisign', ['-Sm', filePath, '-s', key], { stdio: ['ignore', 'pipe', 'pipe'] });
  console.log(result.status === 0 ? `✓ 已签名：${filePath}.minisig` : `○ 签名失败：${result.stderr?.toString().slice(-200)}`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const allTasks = loadCorpus();
  const tasks = options.task ? allTasks.filter((task) => options.task.includes(task.id)) : allTasks;
  if (tasks.length === 0) { console.error('没有匹配的语料任务'); process.exit(2); }

  if (options.checkCorpus) process.exit((await checkCorpus(tasks)) ? 0 : 1);

  const config = loadConfig();
  const harnessNames = options.selfTest
    ? ['echo']
    : (options.harness ?? Object.keys(DRIVERS).filter((name) => name !== 'echo'));
  for (const name of harnessNames) if (!DRIVERS[name]) { console.error(`未知 harness：${name}`); process.exit(2); }

  const runDir = options.resume
    ? join(resultsRoot, options.resume)
    : join(resultsRoot, `${options.selfTest ? 'selftest-' : ''}${stamp()}`);
  const runStamp = runDir.split('/').at(-1) ?? runDir;
  if (options.resume && !existsSync(runDir)) {
    console.error(`恢复目录不存在：${runDir}`);
    process.exit(2);
  }
  ensureDir(runDir);
  const results = await runMatrix({ tasks, harnessNames, config, runs: options.runs, runDir });

  writeFileSync(join(runDir, 'results.jsonl'), results.map((result) => JSON.stringify(result)).join('\n') + '\n');
  const active = results.filter((result) => result.status !== 'skipped');
  const stats = aggregate(active);
  const modelLabel = config.modelLabel ?? null;
  writeFileSync(join(runDir, 'report.json'), JSON.stringify(buildReportJson({ stamp: runStamp, modelLabel, stats, results }), null, 2));
  const markdown = renderMarkdown({ stamp: runStamp, modelLabel, stats, results, tasks });
  writeFileSync(join(runDir, 'report.md'), markdown);
  maybeSign(join(runDir, 'report.md'), options.sign);

  console.log('');
  for (const row of stats) {
    console.log(`${row.harness}：成功 ${row.successes}/${row.runs}，均摊成本/成功 ${row.costPerSolvedUSD === null ? '—' : `$${row.costPerSolvedUSD.toFixed(4)}`}，中位耗时 ${row.medianWallMs === null ? '—' : `${Math.round(row.medianWallMs / 1000)}s`}`);
  }
  console.log(`\n报告 → ${join(runDir, 'report.md')}`);

  if (options.selfTest) {
    const expectedFailures = tasks.filter((task) => task.expect?.pristineFails === true).length;
    const echoFailures = active.filter((result) => !result.success && result.status === 'completed').length;
    const ok = active.length === tasks.length && echoFailures === expectedFailures;
    console.log(ok ? '✓ 自检通过：编排/验证/报告管线正常（echo 对带 bug 语料全部按预期失败）' : '✗ 自检失败：管线行为与预期不符');
    process.exit(ok ? 0 : 1);
  }
  process.exit(0);
}

await main();
