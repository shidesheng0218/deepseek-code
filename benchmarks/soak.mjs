#!/usr/bin/env node
/**
 * 浸泡测试：在故障注入下长时间运行多个会话，验证运行时不变量。
 *
 * 故障注入：Provider 周期性 HTTP 500、SSE 截断。
 * 崩溃注入：慢响应期间 SIGKILL sidecar，随后用同一会话目录重启并 recover。
 *
 * 断言（任一失败即整体失败）：
 * - 每个会话都到达 turn_ended（completed 或 error），不允许悬挂；
 * - 每个会话事件日志的 sequence 严格递增、eventID 不重复；
 * - Provider 故障只产生 error 结束，不产生崩溃或重复事件；
 * - 崩溃恢复后 recover 响应正常，且未知副作用不重放（无 tool_started 重放）。
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const sidecarEntry = join(root, 'apps', 'deepseek-agent-runtime', 'src', 'main.ts');
const bun = join(root, 'node_modules', '@oven', 'bun-darwin-aarch64', 'bin', 'bun');

const SESSIONS = 12;
const failures = [];
function check(condition, message) {
  if (!condition) failures.push(message);
}

function startFlakyProvider() {
  let requests = 0;
  const server = createServer((request, response) => {
    requests += 1;
    request.resume();
    request.on('end', () => {
      if (requests % 4 === 0) {
        response.writeHead(500, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ error: { message: 'injected provider failure' } }));
        return;
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.write(`data: ${JSON.stringify({ choices: [{ delta: { content: '浸泡回复' } }] })}\n\n`);
      if (requests % 7 === 0) { response.end(); return; } // SSE 截断
      response.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 10, completion_tokens: 5 } })}\n\n`);
      response.end('data: [DONE]\n\n');
    });
  });
  return new Promise((resolvePromise) => {
    server.listen(0, '127.0.0.1', () => resolvePromise({
      baseURL: `http://127.0.0.1:${server.address().port}/v1/`,
      close: () => server.close()
    }));
  });
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
  const send = (method, params, timeoutMs = 30_000) => new Promise((resolvePromise, reject) => {
    const id = `soak-${++counter}`;
    const timer = setTimeout(() => { waiters.delete(id); reject(new Error(`${method} timed out`)); }, timeoutMs);
    waiters.set(id, (frame) => { clearTimeout(timer); resolvePromise(frame); });
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

function assertLogInvariants(sessionRoot, sessionID) {
  const events = readSessionEvents(sessionRoot, sessionID);
  const sequences = events.map((event) => event.sequence).filter((value) => typeof value === 'number');
  for (let index = 1; index < sequences.length; index += 1) {
    check(sequences[index] > sequences[index - 1], `${sessionID}: sequence 未严格递增（${sequences[index - 1]} → ${sequences[index]}）`);
  }
  const ids = new Set();
  for (const event of events) {
    if (!event.eventID) continue;
    check(!ids.has(event.eventID), `${sessionID}: eventID 重复 ${event.eventID}`);
    ids.add(event.eventID);
  }
  const ends = events.filter((event) => event.type === 'turn_ended' || (event.payload && event.payload.type === 'turn_ended'));
  check(ends.length > 0, `${sessionID}: 缺少 turn_ended（会话悬挂）`);
  return events;
}

const sessionRoot = mkdtempSync(join(tmpdir(), 'deepseek-soak-'));
const provider = await startFlakyProvider();

// 阶段 1：故障注入下的连续会话
{
  const sidecar = startSidecar(sessionRoot);
  for (let index = 0; index < SESSIONS; index += 1) {
    const sessionID = `soak-session-${index}`;
    try {
      const response = await sidecar.send('session.run', {
        sessionID,
        projectPath: sessionRoot,
        prompt: `第 ${index} 次浸泡提问`,
        baseURL: provider.baseURL,
        apiKey: 'soak-key',
        model: 'soak-model',
        protocol: 'openai-compatible',
        mode: 'auto'
      });
      check(response.type === 'response', `${sessionID}: 无响应`);
      // HTTP 500 与 SSE 截断应转化为 ok=false 或 error 状态，而不是悬挂
    } catch (error) {
      failures.push(`${sessionID}: ${error instanceof Error ? error.message : String(error)}`);
    }
    assertLogInvariants(sessionRoot, sessionID);
  }
  sidecar.child.kill('SIGKILL');
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 300));
}

// 阶段 2：崩溃恢复——慢响应期间 SIGKILL，再重启 recover
{
  const slow = createServer((request, response) => {
    request.resume();
    request.on('end', () => setTimeout(() => {
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: '慢回复' } }] })}\n\ndata: [DONE]\n\n`);
    }, 5_000));
  });
  await new Promise((resolvePromise) => slow.listen(0, '127.0.0.1', resolvePromise));
  const slowURL = `http://127.0.0.1:${slow.address().port}/v1/`;

  const first = startSidecar(sessionRoot);
  const crashSession = 'soak-crash-session';
  const runPromise = first.send('session.run', {
    sessionID: crashSession, projectPath: sessionRoot, prompt: '崩溃注入任务',
    baseURL: slowURL, apiKey: 'k', model: 'm', protocol: 'openai-compatible', mode: 'auto'
  }).catch(() => undefined);
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 1_000));
  first.child.kill('SIGKILL'); // 模型请求中途杀死 sidecar
  await runPromise;
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 300));

  const second = startSidecar(sessionRoot);
  const recover = await second.send('session.recover', { sessionID: crashSession });
  check(recover.ok === true, '崩溃会话 recover 未成功响应');
  const events = readSessionEvents(sessionRoot, crashSession);
  const toolStarts = events.filter((event) => event.type === 'tool_started' || event.payload?.type === 'tool_started');
  check(toolStarts.length === 0, '崩溃后会话不应自动重放任何工具执行');
  const attention = events.filter((event) => (event.type ?? event.payload?.type) === 'recovery_attention' || (event.type ?? event.payload?.type) === 'recovery_input_restored');
  check(attention.length > 0 || recover.result?.resumable === true || recover.result?.restoredInputs > 0, '崩溃会话既未恢复输入也未标记 attention');
  second.child.kill('SIGKILL');
  slow.close();
}

provider.close();

const files = readdirSync(sessionRoot).filter((name) => name.endsWith('.jsonl')).length;
console.log(`会话日志：${files} 个；注入请求已完成`);
if (failures.length > 0) {
  console.error('\n浸泡测试失败：');
  for (const failure of failures) console.error(`  ✗ ${failure}`);
  process.exit(1);
}
console.log(`✓ 浸泡测试通过：${SESSIONS} 个故障注入会话 + 1 个崩溃恢复会话，全部不变量成立`);
