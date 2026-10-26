#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { terminalSession, runSettings } from './terminal-client.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const runtime = process.env.DEEPSEEK_RUNTIME_BINARY || join(root, 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime');
const { userDataDir } = await import('../src/core/platform.ts');
const sessionsRoot = process.env.DEEPSEEK_SESSION_ROOT || join(userDataDir('DeepSeekCode'), 'sessions');

const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));

function printHelp(stream = process.stdout) {
  stream.write(`DeepSeek Code ${version} - terminal coding agent\n\n` +
    'Usage:\n' +
    '  deepseek [options]                         Start an interactive session\n' +
    '  deepseek ask [options] <prompt>            Run one prompt\n' +
    '  deepseek run [options] <prompt>            Alias for ask\n' +
    '  deepseek doctor                            Check the bundled runtime\n' +
    '  deepseek session list|attach|resume ...    Inspect or continue sessions\n' +
    '  deepseek session fork|branches|replay ...  Branch or replay a session\n' +
    '  deepseek receipt verify <file>             Verify a delivery receipt\n\n' +
    'Options:\n' +
    '  --project <path>       Project directory (default: current directory)\n' +
    '  --model <name>         Model name (default: deepseek-chat)\n' +
    '  --base-url <url>       OpenAI-compatible or Anthropic endpoint\n' +
    '  --protocol <name>      openai-compatible | anthropic-messages\n' +
    '  --mode <name>          plan | manual | acceptEdits | auto\n' +
    '  --session <id>         Reuse a session ID\n' +
    '  --fast-model <name>    Optional fast model for routing\n' +
    '  -h, --help             Show this help\n' +
    '  -v, --version          Show the version\n');
}

function usage() {
  printHelp(process.stderr);
  process.exit(2);
}

function parseRunOptions(args) {
  const options = { projectPath: undefined, model: undefined, baseURL: undefined, protocol: undefined, mode: undefined, sessionID: undefined, fastModel: undefined };
  const prompt = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = args[index + 1];
    if (arg === '--') { prompt.push(...args.slice(index + 1)); break; }
    if (arg === '-h' || arg === '--help') { printHelp(); process.exit(0); }
    if (arg === '--project') options.projectPath = next;
    else if (arg === '--model') options.model = next;
    else if (arg === '--base-url') options.baseURL = next;
    else if (arg === '--protocol') options.protocol = next;
    else if (arg === '--mode') options.mode = next;
    else if (arg === '--session') options.sessionID = next;
    else if (arg === '--fast-model') options.fastModel = next;
    else if (arg.startsWith('-')) usage();
    else { prompt.push(arg); continue; }
    if (!next || next.startsWith('-')) usage();
    index += 1;
  }
  return { options, prompt: prompt.join(' ').trim() };
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

/** 离线校验交付回执：重算日志哈希、门禁与证据，逐项给出结论（第三方可复跑）。 */
async function receiptVerifyCommand(file) {
  if (!file) usage();
  const receipt = JSON.parse(await readFile(file, 'utf8'));
  const logFile = join(sessionsRoot, `${safeSessionID(receipt.sessionID)}.jsonl`);
  const text = await readFile(logFile, 'utf8').catch(() => '');
  if (!text) { process.stderr.write(`Session log not found: ${logFile}\n`); process.exit(1); }
  const events = text.split('\n').filter(Boolean).flatMap((line) => {
    try {
      const event = JSON.parse(line);
      return [{ sequence: event.sequence, type: event.type, payload: event.payload }];
    } catch { return []; }
  });
  // Node ≥22.18 自带类型剥离，可直接 import 核心 TS 模块（零依赖、可单文件分发的校验路径）。
  const { verifyDeliveryReceipt } = await import('../src/core/delivery-receipt.ts');
  const { evaluateDeliveryGate } = await import('../src/core/delivery-gate.ts');
  const result = verifyDeliveryReceipt({ receipt, events, evaluateGate: evaluateDeliveryGate });
  for (const check of result.checks) process.stdout.write(`${check.ok ? '✓' : '✗'} ${check.name}：${check.detail}\n`);
  process.stdout.write(result.ok ? `回执有效：会话 ${receipt.sessionID} 的交付声明可复核。\n` : '回执校验失败。\n');
  if (!result.ok) process.exitCode = 1;
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

async function resumeSession(sessionID, options = {}) {
  const id = safeSessionID(sessionID);
  const text = await readFile(join(sessionsRoot, `${id}.jsonl`), 'utf8');
  const approvals = new Map();
  let projectPath;
  for (const line of text.split('\n')) {
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    if (event.type === 'turn_started' && event.payload?.projectPath) projectPath = event.payload.projectPath;
    if (event.type === 'approval_pending') approvals.set(event.payload.approvalID, event.payload);
    if (event.type === 'approval_resolved') approvals.delete(event.payload.approvalID);
    if (event.type === 'tool_indeterminate') throw new Error('Session contains an operation with unknown side effects. Inspect it before continuing; it will not be replayed automatically.');
  }
  const settings = runSettings({ ...(!process.env.DEEPSEEK_PROJECT && projectPath ? { projectPath } : {}), ...options, sessionID: id });
  await terminalSession({ runtime, root, settings, interactive: true, pendingApproval: [...approvals.values()][0] });
}

async function runPrompt(prompt, options = {}) {
  const settings = runSettings(options);
  await terminalSession({ runtime, root, settings, prompt, interactive: false });
}

async function interactive(options = {}) {
  const settings = runSettings(options);
  await terminalSession({ runtime, root, settings, interactive: true });
}

const [command, ...args] = process.argv.slice(2);
try {
  if (command === undefined || command === 'chat' || (command.startsWith('--') && !['--help', '--version'].includes(command))) {
    const parsed = parseRunOptions(command === 'chat' ? args : command ? [command, ...args] : []);
    if (parsed.prompt) usage();
    await interactive(parsed.options);
  } else if (command === '-h' || command === '--help' || command === 'help') printHelp();
  else if (command === '-v' || command === '--version' || command === 'version') process.stdout.write(`${version}\n`);
  else if (command === 'doctor') await doctor();
  else if (command === 'ask' || command === 'run') {
    const parsed = parseRunOptions(args);
    if (!parsed.prompt) {
      if (!process.stdin.isTTY) parsed.prompt = (await new Promise((resolveInput) => { let text = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', (chunk) => { text += chunk; }); process.stdin.on('end', () => resolveInput(text.trim())); })).trim();
      else usage();
    }
    if (!parsed.prompt) usage();
    await runPrompt(parsed.prompt, parsed.options);
  } else if (command === 'session' && args[0] === 'list') await listSessions();
  else if (command === 'session' && args[0] === 'attach' && args[1]) await attachSession(args[1]);
  else if (command === 'session' && args[0] === 'resume' && args[1]) {
    const parsed = parseRunOptions(args.slice(2));
    if (parsed.prompt) usage();
    await resumeSession(args[1], parsed.options);
  }
  else if (command === 'session' && args[0] === 'fork' && args[1]) await forkSessionCommand(args.slice(1));
  else if (command === 'session' && args[0] === 'branches' && args[1]) await branchesCommand(args[1]);
  else if (command === 'session' && args[0] === 'replay' && args[1]) await replayCommand(args.slice(1));
  else if (command === 'receipt' && args[0] === 'verify' && args[1]) await receiptVerifyCommand(args[1]);
  else usage();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
