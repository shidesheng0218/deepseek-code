#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const runtime = process.env.DEEPSEEK_RUNTIME_BINARY || join(root, 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime');
const sessionsRoot = process.env.DEEPSEEK_SESSION_ROOT || join(process.env.HOME || '.', 'Library/Application Support/DeepSeekCode/sessions');

function usage() {
  process.stderr.write('Usage: deepseek doctor | ask <prompt> | run <prompt> | session list | session attach <id> | session resume <id> | session fork <id> [--at N] [--reason text] | session branches <id> | session replay <id> [--at N]\n');
  process.exit(2);
}

/** 向 sidecar 发送单个请求并等待对应响应帧。 */
function requestSidecar(method, params) {
  return new Promise((resolve, reject) => {
    const id = `cli-${method}-${Date.now()}`;
    const child = spawn(runtime, ['--stdio'], { cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
    let buffer = '';
    let stderr = '';
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Sidecar request timed out')); }, 30_000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n'); buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        let frame; try { frame = JSON.parse(line); } catch { continue; }
        if (frame.type === 'response' && frame.id === id) {
          clearTimeout(timeout);
          child.kill('SIGTERM');
          resolve(frame);
        }
      }
    });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
    child.once('exit', () => { clearTimeout(timeout); reject(new Error(`Sidecar exited before responding${stderr ? `: ${stderr.slice(-200)}` : ''}`)); });
    child.stdin.end(`${JSON.stringify({ id, method, params })}\n`);
  });
}

function parseForkArgs(args) {
  const options = { sessionID: args[0], baseSequence: undefined, reason: undefined, untilSequence: undefined };
  for (let index = 1; index < args.length; index += 1) {
    if (args[index] === '--at') { options.baseSequence = Number.parseInt(args[index + 1], 10) || undefined; options.untilSequence = options.baseSequence; index += 1; }
    else if (args[index] === '--reason') { options.reason = args[index + 1]; index += 1; }
    else usage();
  }
  return options;
}

async function forkSessionCommand(args) {
  const options = parseForkArgs(args);
  if (!options.sessionID) usage();
  const response = await requestSidecar('session.fork', {
    sessionID: safeSessionID(options.sessionID),
    ...(options.baseSequence ? { baseSequence: options.baseSequence } : {}),
    ...(options.reason ? { reason: options.reason } : {})
  });
  if (!response.ok) { process.stderr.write(`${response.error ?? 'fork failed'}\n`); process.exit(1); }
  const result = response.result;
  process.stdout.write(`${result.sessionID}\t分叉自 ${result.sourceSessionID}@${result.baseSequence}（继承 ${result.inheritedMessages} 条消息）\n`);
}

async function branchesCommand(sessionID) {
  const response = await requestSidecar('session.branches', { sessionID: safeSessionID(sessionID) });
  if (!response.ok) { process.stderr.write(`${response.error ?? 'branches failed'}\n`); process.exit(1); }
  const branches = response.result.branches ?? [];
  if (branches.length === 0) { process.stdout.write('（无分叉）\n'); return; }
  for (const branch of branches) process.stdout.write(`${branch.sessionID}\t@${branch.baseSequence}\n`);
}

async function replayCommand(args) {
  const options = parseForkArgs(args);
  if (!options.sessionID) usage();
  const response = await requestSidecar('session.replay', {
    sessionID: safeSessionID(options.sessionID),
    ...(options.untilSequence ? { untilSequence: options.untilSequence } : {})
  });
  if (!response.ok) { process.stderr.write(`${response.error ?? 'replay failed'}\n`); process.exit(1); }
  const result = response.result;
  const verdict = result.matched === null ? '（部分回放，无比对）' : result.matched ? '一致 ✓' : '不一致 ✗';
  process.stdout.write(`回放校验：${verdict}\n门禁重算：${result.gateState}${result.recordedState ? `（记录：${result.recordedState}）` : ''}\n事件 ${result.eventCount} 条 · 对话 ${result.turns} 条\n`);
  if (result.matched === false) process.exitCode = 1;
}

function runProcess(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(runtime, args, { cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (code) => resolve({ code: code ?? 1, stdout, stderr }));
    if (input !== undefined) child.stdin.end(input); else child.stdin.end();
  });
}

async function doctor() {
  const result = await runProcess(['health']);
  if (result.code !== 0) { process.stderr.write(result.stderr || 'DeepSeek Sidecar unavailable\n'); process.exit(result.code); }
  process.stdout.write(result.stdout.trim() + '\n');
}

function safeSessionID(value) {
  if (!value || !/^[A-Za-z0-9._-]+$/.test(value)) throw new Error('Invalid session ID');
  return value;
}

async function sessionEntries() {
  let names = [];
  try { names = await readdir(sessionsRoot); } catch { return []; }
  return Promise.all(names.filter((name) => name.endsWith('.jsonl')).map(async (name) => {
    const sessionID = name.slice(0, -'.jsonl'.length);
    if (!/^[A-Za-z0-9._-]+$/.test(sessionID)) return undefined;
    const text = await readFile(join(sessionsRoot, name), 'utf8').catch(() => '');
    let title = sessionID;
    for (const line of text.split('\n')) {
      try {
        const event = JSON.parse(line);
        if (event.type === 'turn_started' && typeof event.payload?.prompt === 'string') { title = event.payload.prompt.slice(0, 56); break; }
      } catch { /* Ignore a partially written event. */ }
    }
    return { sessionID, title };
  })).then((items) => items.filter(Boolean));
}

async function listSessions() {
  for (const entry of await sessionEntries()) process.stdout.write(`${entry.sessionID}\t${entry.title}\n`);
}

async function attachSession(sessionID) {
  const file = join(sessionsRoot, `${safeSessionID(sessionID)}.jsonl`);
  const text = await readFile(file, 'utf8').catch(() => '');
  if (!text) { process.stderr.write('Session not found\n'); process.exit(1); }
  let assistant = '';
  for (const line of text.split('\n')) {
    try {
      const event = JSON.parse(line);
      if (event.type === 'turn_started' && typeof event.payload?.prompt === 'string') process.stdout.write(`你：${event.payload.prompt}\n`);
      if (event.type === 'assistant_text' && typeof event.payload?.text === 'string') assistant += event.payload.text;
      if (event.type === 'turn_ended' && assistant) { process.stdout.write(`DeepSeek：${assistant}\n`); assistant = ''; }
    } catch { /* Ignore a partial last line. */ }
  }
}

async function resumeSession(sessionID) {
  const id = safeSessionID(sessionID);
  const baseURL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com/v1';
  const apiKey = process.env.DEEPSEEK_API_KEY || '';
  const model = process.env.DEEPSEEK_MODEL || 'deepseek-chat';
  const projectPath = process.env.DEEPSEEK_PROJECT || process.cwd();
  if (!apiKey) { process.stderr.write('Set DEEPSEEK_API_KEY before resuming.\n'); process.exit(2); }
  const child = spawn(runtime, ['--stdio'], { cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  child.stdout.setEncoding('utf8');
  const done = new Promise((resolve) => {
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n'); buffer = lines.pop() || '';
      for (const line of lines) {
        if (!line.trim()) continue;
        let frame; try { frame = JSON.parse(line); } catch { continue; }
        if (frame.type === 'event' && frame.event?.type === 'assistant_text') process.stdout.write(frame.event.text || '');
        if (frame.type === 'event' && frame.event?.type === 'approval_required') process.stderr.write(`\nApproval required: ${frame.event.tool || 'tool'}\n`);
        if (frame.type === 'response' && frame.result?.text !== undefined) { process.stdout.write(`\n${frame.result.text}\n`); resolve(); }
      }
    });
  });
  child.stdin.write(`${JSON.stringify({ id: `cli-resume-${Date.now()}`, method: 'session.recover', params: { sessionID: id, projectPath, baseURL, apiKey, model, protocol: process.env.DEEPSEEK_PROTOCOL || 'openai-compatible', mode: 'auto' } })}\n`);
  await done;
  child.kill('SIGTERM');
}

async function runPrompt(prompt) {
  const baseURL = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com/v1';
  const apiKey = process.env.DEEPSEEK_API_KEY || '';
  const model = process.env.DEEPSEEK_MODEL || 'deepseek-chat';
  const projectPath = process.env.DEEPSEEK_PROJECT || process.cwd();
  if (!apiKey) { process.stderr.write('Set DEEPSEEK_API_KEY before running ask.\n'); process.exit(2); }
  const sessionID = process.env.DEEPSEEK_SESSION_ID || `cli-${Date.now()}`;
  const child = spawn(runtime, ['--stdio'], { cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    const lines = buffer.split('\n'); buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let frame; try { frame = JSON.parse(line); } catch { continue; }
      if (frame.type === 'event' && frame.event?.type === 'assistant_text') process.stdout.write(frame.event.text || '');
      if (frame.type === 'response' && frame.result?.text !== undefined) { if (!frame.event) process.stdout.write(`\n${frame.result.text}\n`); child.kill('SIGTERM'); }
      if (frame.type === 'event' && frame.event?.type === 'approval_required') process.stderr.write(`\nApproval required: ${frame.event.tool || 'tool'}\n`);
    }
  });
  child.stderr.pipe(process.stderr);
  child.once('error', (error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
  child.stdin.end(`${JSON.stringify({ id: `cli-${Date.now()}`, method: 'session.run', params: { sessionID, projectPath, prompt, baseURL, apiKey, model, protocol: process.env.DEEPSEEK_PROTOCOL || 'openai-compatible', mode: 'auto' } })}\n`);
}

const [command, ...args] = process.argv.slice(2);
try {
  if (command === 'doctor') await doctor();
  else if (command === 'ask' || command === 'run') await runPrompt(args.join(' ').trim() || usage());
  else if (command === 'session' && args[0] === 'list') await listSessions();
  else if (command === 'session' && args[0] === 'attach' && args[1]) await attachSession(args[1]);
  else if (command === 'session' && args[0] === 'resume' && args[1]) await resumeSession(args[1]);
  else if (command === 'session' && args[0] === 'fork' && args[1]) await forkSessionCommand(args.slice(1));
  else if (command === 'session' && args[0] === 'branches' && args[1]) await branchesCommand(args[1]);
  else if (command === 'session' && args[0] === 'replay' && args[1]) await replayCommand(args.slice(1));
  else usage();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
