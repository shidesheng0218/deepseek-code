#!/usr/bin/env node
/**
 * 基准运行器：对每个 fixture 启动独立 sidecar，用 mock 或真实 Provider
 * 执行任务，采集事件日志到 benchmarks/results/<run>/<fixture>.json。
 *
 * mock 模式：内置 SSE Provider，按 fixture.mockReply 返回固定文本，
 * 用于确定性地验证路由、工具约束与交付门禁逻辑。
 * real 模式（--real）：使用 DEEPSEEK_API_KEY/DEEPSEEK_BASE_URL/DEEPSEEK_MODEL。
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readdirSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const fixturesDir = join(root, 'benchmarks', 'fixtures');
const resultsDir = join(root, 'benchmarks', 'results');
const sidecarEntry = join(root, 'apps/deepseek-agent-runtime/src/main.ts');
const bun = join(root, 'node_modules/@oven/bun-darwin-aarch64/bin/bun');
const real = process.argv.includes('--real');

function loadFixtures() {
  return readdirSync(fixturesDir).filter((name) => name.endsWith('.json'))
    .map((name) => JSON.parse(readFileSync(join(fixturesDir, name), 'utf8')));
}

function startMockProvider(fixtures) {
  const replies = new Map(fixtures.map((fixture) => [fixture.id, fixture.mockReply ?? '已完成。']));
  let lastFixture = 'unknown';
  const server = createServer((request, response) => {
    request.resume();
    request.on('end', () => {
      const reply = replies.get(lastFixture) ?? '已完成。';
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: reply } }] })}\n\n`);
      response.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 120, completion_tokens: 30, prompt_tokens_details: { cached_tokens: 0 } } })}\n\n`);
      response.end('data: [DONE]\n\n');
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({
      baseURL: `http://127.0.0.1:${server.address().port}/v1/`,
      apiKey: 'bench-mock-key',
      model: 'bench-mock-model',
      setFixture: (id) => { lastFixture = id; },
      close: () => server.close()
    }));
  });
}

function runFixture(fixture, provider, runDir) {
  return new Promise((resolvePromise, reject) => {
    const sessionRoot = mkdtempSync(join(tmpdir(), 'deepseek-bench-'));
    const projectPath = fixture.projectPath ?? mkdtempSync(join(tmpdir(), 'deepseek-bench-project-'));
    const child = spawn(bun, [sidecarEntry, '--stdio'], {
      cwd: root,
      env: { ...process.env, DEEPSEEK_SESSION_ROOT: sessionRoot },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    const frames = [];
    let buffer = '';
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`fixture ${fixture.id} timed out`)); }, fixture.timeoutMs ?? 60_000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        let frame;
        try { frame = JSON.parse(line); } catch { continue; }
        frames.push(frame);
        if (frame.type === 'response') {
          clearTimeout(timeout);
          child.kill('SIGTERM');
          const events = frames.filter((item) => item.type === 'event').map((item) => item.event);
          writeFileSync(join(runDir, `${fixture.id}.json`), JSON.stringify({ fixture, frames, events }, null, 2));
          resolvePromise({ fixture, frames, events, response: frame });
        }
      }
    });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
    provider.setFixture?.(fixture.id);
    child.stdin.write(`${JSON.stringify({
      id: `bench-${fixture.id}`,
      method: 'session.run',
      params: {
        sessionID: `bench-${fixture.id}`,
        projectPath,
        prompt: fixture.prompt,
        baseURL: provider.baseURL,
        apiKey: provider.apiKey,
        model: provider.model,
        protocol: 'openai-compatible',
        mode: 'auto'
      }
    })}\n`);
  });
}

export function evaluate(fixture, events, response) {
  const failures = [];
  const expect = fixture.expect ?? {};
  if (expect.route) {
    const decision = events.find((event) => event.type === 'decision_made');
    if (decision?.route !== expect.route) failures.push(`route: expected ${expect.route}, got ${decision?.route ?? 'none'}`);
  }
  if (expect.noToolCalls && events.some((event) => event.type === 'tool_started')) failures.push('noToolCalls: a tool was started');
  if (typeof expect.maxApprovals === 'number') {
    const approvals = events.filter((event) => event.type === 'approval_required').length;
    if (approvals > expect.maxApprovals) failures.push(`maxApprovals: ${approvals} > ${expect.maxApprovals}`);
  }
  if (expect.delivery) {
    const delivery = [...events].reverse().find((event) => event.type === 'delivery_evaluated');
    if (delivery?.state !== expect.delivery) failures.push(`delivery: expected ${expect.delivery}, got ${delivery?.state ?? 'none'}`);
  }
  if (expect.mustMention) {
    const text = response?.result?.text ?? '';
    for (const keyword of expect.mustMention) if (!text.includes(keyword)) failures.push(`mustMention: missing "${keyword}"`);
  }
  if (expect.mustContain) {
    const text = response?.result?.text ?? '';
    for (const keyword of expect.mustContain) if (!text.includes(keyword)) failures.push(`mustContain: missing "${keyword}"`);
  }
  if (expect.mustCall) {
    const called = new Set(events.filter((event) => event.type === 'tool_started').map((event) => event.tool));
    for (const tool of expect.mustCall) if (!called.has(tool)) failures.push(`mustCall: "${tool}" was not called`);
  }
  if (expect.mustNotCall) {
    const called = new Set(events.filter((event) => event.type === 'tool_started').map((event) => event.tool));
    for (const tool of expect.mustNotCall) if (called.has(tool)) failures.push(`mustNotCall: "${tool}" was called`);
  }
  return failures;
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const allFixtures = loadFixtures();
  // Fixtures requiring real tool execution are skipped in mock mode: the mock
  // provider never issues tool calls, so mustCall assertions are only
  // meaningful against a real model.
  const fixtures = real ? allFixtures : allFixtures.filter((fixture) => !fixture.expect?.mustCall);
  const runDir = join(resultsDir, new Date().toISOString().replace(/[:.]/g, '-'));
  mkdirSync(runDir, { recursive: true });
  const provider = real
    ? { baseURL: process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com/v1', apiKey: process.env.DEEPSEEK_API_KEY ?? '', model: process.env.DEEPSEEK_MODEL ?? 'deepseek-chat' }
    : await startMockProvider(fixtures);
  if (real && !provider.apiKey) { console.error('Set DEEPSEEK_API_KEY for --real runs'); process.exit(2); }

  let passed = 0;
  const summary = [];
  for (const fixture of fixtures) {
    try {
      const { events, response } = await runFixture(fixture, provider, runDir);
      const failures = evaluate(fixture, events, response);
      if (failures.length === 0) { passed += 1; summary.push({ id: fixture.id, ok: true }); }
      else summary.push({ id: fixture.id, ok: false, failures });
    } catch (error) {
      summary.push({ id: fixture.id, ok: false, failures: [error instanceof Error ? error.message : String(error)] });
    }
  }
  writeFileSync(join(runDir, 'summary.json'), JSON.stringify({ run: runDir, real, passed, total: fixtures.length, summary }, null, 2));
  for (const item of summary) console.log(`${item.ok ? '✓' : '✗'} ${item.id}${item.failures ? ` — ${item.failures.join('; ')}` : ''}`);
  console.log(`\n${passed}/${fixtures.length} fixtures passed (${allFixtures.length - fixtures.length} skipped in mock mode) → ${runDir}`);
  provider.close?.();
  process.exit(passed === fixtures.length ? 0 : 1);
}
