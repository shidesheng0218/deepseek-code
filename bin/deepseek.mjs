#!/usr/bin/env node
import { access, mkdir, readdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { spawn, execFile } from 'node:child_process';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { terminalSession, runSettings } from './terminal-client.mjs';
import { listConfig, setConfigValue, unsetConfigValue, loadConfig } from './cli-config.mjs';

const execFileAsync = promisify(execFile);

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const runtime = process.env.DEEPSEEK_RUNTIME_BINARY || join(root, 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime');
const { userDataDir } = await import('../src/core/platform.ts');
const sessionsRoot = process.env.DEEPSEEK_SESSION_ROOT || join(userDataDir('DeepSeekCode'), 'sessions');
const archivedRoot = join(sessionsRoot, '.archive');

const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));

function printHelp(stream = process.stdout) {
  stream.write(`DeepSeek Code ${version} - terminal coding agent\n\n` +
    'Usage:\n' +
    '  deepseek [options]                         Start an interactive session\n' +
    '  deepseek ask [options] <prompt>            Run one prompt (supports --json)\n' +
    '  deepseek run [options] <prompt>            Alias for ask\n' +
    '  deepseek init                              Interactive first-time setup\n' +
    '  deepseek config list|get|set|unset ...     Manage layered configuration\n' +
    '  deepseek doctor [--json]                   Diagnose runtime and connectivity\n' +
    '  deepseek diff [--stat] [--json]            Show working tree changes\n' +
    '  deepseek session list|show|search|rename|archive|attach|resume ...\n' +
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
    '  --json                 Emit machine-readable JSON (ask/doctor/diff/session)\n' +
    '  -h, --help             Show this help\n' +
    '  -v, --version          Show the version\n');
}

function usage() {
  printHelp(process.stderr);
  process.exit(2);
}

function parseRunOptions(args) {
  const options = { projectPath: undefined, model: undefined, baseURL: undefined, protocol: undefined, mode: undefined, sessionID: undefined, fastModel: undefined, json: false };
  const prompt = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = args[index + 1];
    if (arg === '--') { prompt.push(...args.slice(index + 1)); break; }
    if (arg === '-h' || arg === '--help') { printHelp(); process.exit(0); }
    if (arg === '--json') { options.json = true; continue; }
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

async function doctor({ json = false } = {}) {
  const checks = [];
  const add = (name, ok, detail, level = ok ? 'ok' : 'fail') => checks.push({ name, ok, level, detail });

  add('runtime-binary', await access(runtime).then(() => true).catch(() => false), runtime);
  const health = await runProcess(['health']);
  add('runtime-health', health.code === 0, health.code === 0 ? health.stdout.trim() : (health.stderr || 'unavailable'));
  add('api-key', Boolean(process.env.DEEPSEEK_API_KEY), process.env.DEEPSEEK_API_KEY ? 'DEEPSEEK_API_KEY is set' : 'Set DEEPSEEK_API_KEY to run tasks');

  const projectPath = resolvePath(process.env.DEEPSEEK_PROJECT || process.cwd());
  const { values, sources } = await loadConfig({ projectPath });
  add('config', true, Object.entries(values).map(([k, v]) => `${k}=${v} (${sources[k] ?? '-'})`).join(', '), 'ok');

  let endpointOk = false; let endpointDetail = '';
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    const res = await fetch(values.baseURL.replace(/\/$/, '') + '/models', {
      headers: process.env.DEEPSEEK_API_KEY ? { authorization: `Bearer ${process.env.DEEPSEEK_API_KEY}` } : {},
      signal: controller.signal
    }).finally(() => clearTimeout(timer));
    endpointOk = res.status < 500;
    endpointDetail = `HTTP ${res.status}`;
    if (res.status === 401 || res.status === 403) endpointDetail += ' (authentication failed — check DEEPSEEK_API_KEY)';
  } catch (error) {
    endpointDetail = error instanceof Error ? error.message : String(error);
  }
  add('endpoint', endpointOk, `${values.baseURL} → ${endpointDetail}`, endpointOk ? 'ok' : 'fail');

  const browserDir = process.env.DEEPSEEK_BROWSER_RUNTIME_DIR;
  add('browser-runtime', Boolean(browserDir), browserDir ? browserDir : 'optional; set DEEPSEEK_BROWSER_RUNTIME_DIR for Browser Evidence', browserDir ? 'ok' : 'warn');

  const failed = checks.some((c) => c.level === 'fail');
  if (json) {
    process.stdout.write(JSON.stringify({ ok: !failed, version, runtime, sessionsRoot, checks }, null, 2) + '\n');
  } else {
    for (const c of checks) process.stdout.write(`${c.level === 'ok' ? '✓' : c.level === 'warn' ? '!' : '✗'} ${c.name}: ${c.detail}\n`);
    process.stdout.write(failed ? 'Doctor found problems.\n' : 'All checks passed.\n');
  }
  if (failed) process.exitCode = 1;
}

async function initCommand() {
  if (!process.stdin.isTTY) { process.stderr.write('deepseek init requires a terminal.\n'); process.exit(2); }
  const { createInterface } = await import('node:readline');
  const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: true });
  const ask = (label, fallback) => new Promise((done) => rl.question(label, (answer) => done(answer.trim() || fallback)));
  try {
    process.stderr.write('DeepSeek Code 初始化（凭据不写入配置文件）\n');
    const baseURL = await ask(`Base URL [https://api.deepseek.com/v1]: `, 'https://api.deepseek.com/v1');
    const model = await ask(`Model [deepseek-chat]: `, 'deepseek-chat');
    const protocol = await ask(`Protocol (openai-compatible|anthropic-messages) [openai-compatible]: `, 'openai-compatible');
    const scopeAnswer = await ask(`保存到用户配置还是项目配置？(user|project) [user]: `, 'user');
    const scope = scopeAnswer === 'project' ? 'project' : 'user';
    await setConfigValue('baseURL', baseURL, { scope, projectPath: process.cwd() });
    await setConfigValue('model', model, { scope, projectPath: process.cwd() });
    await setConfigValue('protocol', protocol, { scope, projectPath: process.cwd() });
    if (!process.env.DEEPSEEK_API_KEY) {
      process.stderr.write('\n未检测到 DEEPSEEK_API_KEY。请在 shell 中设置：\n  export DEEPSEEK_API_KEY="sk-..."\n');
    }
    process.stderr.write('\n配置已保存。运行 deepseek doctor 验证。\n');
    await doctor({});
  } finally { rl.close(); }
}

async function configCommand(args) {
  const [sub, ...rest] = args;
  if (sub === 'list') {
    for (const item of await listConfig({ projectPath: process.cwd() })) {
      process.stdout.write(`${item.key}\t${item.value ?? '-'}\t${item.source ?? '-'}\n`);
    }
    return;
  }
  if (sub === 'get' && rest[0]) {
    const { getConfigKey } = await import('./cli-config.mjs');
    const item = await getConfigKey(rest[0], { projectPath: process.cwd() });
    process.stdout.write(`${item.value ?? ''}\n`);
    return;
  }
  if (sub === 'set' && rest[0] && rest[1]) {
    const parsed = parseScope(rest.slice(2));
    const result = await setConfigValue(rest[0], rest[1], { scope: parsed.scope, projectPath: process.cwd() });
    process.stdout.write(`${result.scope}: ${result.key}=${result.value} (${result.file})\n`);
    return;
  }
  if (sub === 'unset' && rest[0]) {
    const parsed = parseScope(rest.slice(1));
    const result = await unsetConfigValue(rest[0], { scope: parsed.scope, projectPath: process.cwd() });
    process.stdout.write(`unset ${result.key} (${result.file})\n`);
    return;
  }
  process.stderr.write('Usage: deepseek config list | get <key> | set <key> <value> [--scope user|project] | unset <key> [--scope user|project]\n');
  process.exit(2);
}

function parseScope(args) {
  const index = args.indexOf('--scope');
  if (index < 0) return { scope: 'user' };
  const value = args[index + 1];
  if (value !== 'user' && value !== 'project') { process.stderr.write('--scope must be user or project\n'); process.exit(2); }
  return { scope: value };
}

async function diffCommand(args) {
  const json = args.includes('--json');
  const statOnly = args.includes('--stat');
  const projectPath = resolvePath(process.env.DEEPSEEK_PROJECT || process.cwd());
  const run = async (gitArgs) => {
    try { return (await execFileAsync('git', gitArgs, { cwd: projectPath, maxBuffer: 10_000_000 })).stdout; }
    catch (error) { throw new Error(`git ${gitArgs.join(' ')} failed: ${error instanceof Error ? error.message : String(error)}`); }
  };
  const statOut = await run(['diff', '--stat', 'HEAD']);
  const nameStatus = await run(['diff', '--name-status', 'HEAD']);
  const files = nameStatus.split('\n').filter(Boolean).map((line) => {
    const [status, ...pathParts] = line.split('\t');
    return { status, path: pathParts.join('\t') };
  });
  const head = await run(['rev-parse', '--short', 'HEAD']).catch(() => '');
  if (json) {
    const shortstat = (await run(['diff', '--shortstat', 'HEAD'])).trim();
    process.stdout.write(JSON.stringify({ projectPath, head: head.trim(), files, shortstat }, null, 2) + '\n');
    return;
  }
  if (!statOut.trim()) { process.stdout.write('工作区无变更。\n'); return; }
  process.stdout.write(statOut);
  if (!statOnly) process.stdout.write(await run(['diff', 'HEAD']));
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
    const file = join(sessionsRoot, name);
    const text = await readFile(file, 'utf8').catch(() => '');
    let title = sessionID;
    let projectPath;
    let turns = 0;
    let pendingApprovals = 0;
    let lastStatus;
    for (const line of text.split('\n')) {
      try {
        const event = JSON.parse(line);
        if (event.type === 'turn_started') {
          turns += 1;
          if (typeof event.payload?.prompt === 'string' && title === sessionID) title = event.payload.prompt.slice(0, 56);
          if (typeof event.payload?.projectPath === 'string') projectPath = event.payload.projectPath;
        }
        if (event.type === 'approval_pending') pendingApprovals += 1;
        if (event.type === 'approval_resolved') pendingApprovals = Math.max(0, pendingApprovals - 1);
        if (event.type === 'turn_ended' && typeof event.payload?.status === 'string') lastStatus = event.payload.status;
        if (event.type === 'delivery_evaluated' && typeof event.payload?.state === 'string') lastStatus = event.payload.state;
      } catch { /* Ignore a partially written event. */ }
    }
    const info = await stat(file).catch(() => undefined);
    return { sessionID, title, projectPath, turns, pendingApprovals, lastStatus, updatedAt: info?.mtime.toISOString() };
  })).then((items) => items.filter(Boolean));
}

async function listSessions({ json = false } = {}) {
  const entries = await sessionEntries();
  if (json) { process.stdout.write(JSON.stringify(entries, null, 2) + '\n'); return; }
  for (const entry of entries) process.stdout.write(`${entry.sessionID}\t${entry.turns}轮\t${entry.lastStatus ?? '-'}\t${entry.title}\n`);
}

async function showSession(sessionID, { json = false } = {}) {
  const id = safeSessionID(sessionID);
  const entry = (await sessionEntries()).find((item) => item.sessionID === id);
  if (!entry) { process.stderr.write('Session not found\n'); process.exit(1); }
  if (json) { process.stdout.write(JSON.stringify(entry, null, 2) + '\n'); return; }
  process.stdout.write(`Session:   ${entry.sessionID}\n标题:      ${entry.title}\n项目:      ${entry.projectPath ?? '-'}\n轮次:      ${entry.turns}\n状态:      ${entry.lastStatus ?? '-'}\n待审批:    ${entry.pendingApprovals}\n更新时间:  ${entry.updatedAt ?? '-'}\n`);
}

async function searchSessions(keyword) {
  if (!keyword) usage();
  const lowered = keyword.toLowerCase();
  for (const entry of await sessionEntries()) {
    if (entry.sessionID.toLowerCase().includes(lowered) || entry.title.toLowerCase().includes(lowered)) {
      process.stdout.write(`${entry.sessionID}\t${entry.title}\n`);
    }
  }
}

async function renameSession(sessionID, title) {
  const id = safeSessionID(sessionID);
  if (!title) usage();
  const file = join(sessionsRoot, `${id}.jsonl`);
  await access(file).catch(() => { process.stderr.write('Session not found\n'); process.exit(1); });
  const metaFile = join(sessionsRoot, '.meta.json');
  let meta = {};
  try { meta = JSON.parse(await readFile(metaFile, 'utf8')); } catch { meta = {}; }
  meta[id] = { ...(meta[id] ?? {}), title };
  await writeFile(metaFile, JSON.stringify(meta, null, 2) + '\n', { mode: 0o600 });
  process.stdout.write(`${id}\t${title}\n`);
}

async function archiveSession(sessionID) {
  const id = safeSessionID(sessionID);
  const file = join(sessionsRoot, `${id}.jsonl`);
  await mkdir(archivedRoot, { recursive: true });
  await rename(file, join(archivedRoot, `${id}.jsonl`)).catch(() => { process.stderr.write('Session not found\n'); process.exit(1); });
  process.stdout.write(`已归档 ${id}\n`);
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
  const settings = await runSettings({ ...(!process.env.DEEPSEEK_PROJECT && projectPath ? { projectPath } : {}), ...options, sessionID: id });
  await terminalSession({ runtime, root, settings, interactive: true, pendingApproval: [...approvals.values()][0] });
}

async function runPrompt(prompt, options = {}) {
  const settings = await runSettings(options);
  await terminalSession({ runtime, root, settings, prompt, interactive: false, json: options.json });
}

async function interactive(options = {}) {
  const settings = await runSettings(options);
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
  else if (command === 'doctor') await doctor({ json: args.includes('--json') });
  else if (command === 'init') await initCommand();
  else if (command === 'config') await configCommand(args);
  else if (command === 'diff') await diffCommand(args);
  else if (command === 'ask' || command === 'run') {
    const parsed = parseRunOptions(args);
    if (!parsed.prompt) {
      if (!process.stdin.isTTY) parsed.prompt = (await new Promise((resolveInput) => { let text = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', (chunk) => { text += chunk; }); process.stdin.on('end', () => resolveInput(text.trim())); })).trim();
      else usage();
    }
    if (!parsed.prompt) usage();
    await runPrompt(parsed.prompt, parsed.options);
  } else if (command === 'session' && args[0] === 'list') await listSessions({ json: args.includes('--json') });
  else if (command === 'session' && args[0] === 'show' && args[1]) await showSession(args[1], { json: args.includes('--json') });
  else if (command === 'session' && args[0] === 'search' && args[1]) await searchSessions(args[1]);
  else if (command === 'session' && args[0] === 'rename' && args[1] && args[2]) await renameSession(args[1], args.slice(2).join(' '));
  else if (command === 'session' && args[0] === 'archive' && args[1]) await archiveSession(args[1]);
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
