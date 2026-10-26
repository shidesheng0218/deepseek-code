import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

function display(value) {
  // Terminal control sequences are intentionally removed before output.
  // eslint-disable-next-line no-control-regex
  return String(value).replace(/\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '').replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '');
}

export async function runSettings(options = {}, env = process.env, config) {
  if (!config) {
    const { loadConfig } = await import('./cli-config.mjs');
    const projectPath = resolve(options.projectPath || env.DEEPSEEK_PROJECT || process.cwd());
    config = await loadConfig({ projectPath, env, overrides: options });
  }
  const mode = config.values.mode ?? 'auto';
  const protocol = config.values.protocol ?? 'openai-compatible';
  if (!['plan', 'manual', 'accept_edits', 'auto'].includes(mode)) throw new Error(`Invalid mode: ${mode}`);
  if (!['openai-compatible', 'anthropic-messages'].includes(protocol)) throw new Error(`Invalid protocol: ${protocol}`);
  const apiKey = env.DEEPSEEK_API_KEY;
  if (!apiKey) throw new Error('Set DEEPSEEK_API_KEY before starting a session. Run `deepseek init` for setup guidance.');
  const sessionID = options.sessionID || env.DEEPSEEK_SESSION_ID || `cli-${randomUUID()}`;
  if (!/^[A-Za-z0-9._-]+$/.test(sessionID)) throw new Error('Invalid session ID');
  const projectPath = resolve(options.projectPath || env.DEEPSEEK_PROJECT || process.cwd());
  const fastModel = config.values.fastModel;
  return {
    sessionID,
    projectPath,
    baseURL: config.values.baseURL ?? 'https://api.deepseek.com/v1',
    apiKey,
    model: config.values.model ?? 'deepseek-chat',
    protocol,
    mode,
    ...(fastModel ? { fastModel } : {})
  };
}

/** One runtime connection serves all turns and approval continuations. */
export class RuntimeClient {
  constructor(binary, cwd, sessionID) {
    this.pending = new Map();
    this.sessionID = sessionID;
    this.onEvent = () => {};
    this.closed = false;
    this.child = spawn(binary, ['--stdio'], { cwd, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
    let buffer = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        let frame;
        try { frame = JSON.parse(line); } catch { continue; }
        if (frame.type === 'event' && frame.sessionID === this.sessionID) this.onEvent(frame.event);
        if (frame.type !== 'response') continue;
        const waiter = this.pending.get(frame.id);
        if (!waiter) continue;
        this.pending.delete(frame.id);
        if (frame.ok) waiter.resolve(frame.result);
        else waiter.reject(new Error(frame.error || 'Runtime request failed'));
      }
    });
    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (chunk) => process.stderr.write(display(chunk)));
    const fail = (error) => {
      this.failure = error;
      for (const waiter of this.pending.values()) waiter.reject(error);
      this.pending.clear();
    };
    this.child.once('error', (error) => {
      fail(new Error(`Cannot start runtime: ${error.message}. Run npm run build first.`));
      this.closed = true;
    });
    this.child.stdin.on('error', fail);
    this.child.once('exit', (code, signal) => {
      this.closed = true;
      fail(new Error(`Runtime exited (${signal || code}) before completing the request.`));
    });
  }

  request(method, params) {
    if (this.closed || this.failure) return Promise.reject(this.failure || new Error('Runtime is closed'));
    const id = `cli-${randomUUID()}`;
    return new Promise((resolveRequest, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('Runtime request timed out.'));
      }, 30000);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolveRequest(value); },
        reject: (error) => { clearTimeout(timer); reject(error); }
      });
      try {
        this.child.stdin.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
          if (!error) return;
          this.pending.delete(id);
          clearTimeout(timer);
          reject(error);
        });
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  async close() {
    if (this.closed) return;
    await new Promise((done) => {
      const timer = setTimeout(() => { this.child.kill('SIGKILL'); }, 1500);
      this.child.once('exit', () => { clearTimeout(timer); done(); });
      this.child.kill('SIGTERM');
    });
  }
}

export async function terminalSession({ runtime, root, settings, prompt, interactive, pendingApproval, json = false }) {
  if (interactive && !process.stdin.isTTY) throw new Error('Interactive chat requires a terminal. Pipe a prompt to deepseek ask instead.');
  // The iterator is created immediately so fast, pasted lines are not lost.
  const input = process.stdin.isTTY ? createInterface({ input: process.stdin, output: process.stderr, terminal: true }) : undefined;
  const lines = input?.[Symbol.asyncIterator]();
  const question = async (label) => {
    process.stderr.write(label);
    const answer = await lines.next();
    return answer.done ? undefined : answer.value.trim();
  };
  const client = new RuntimeClient(runtime, root, settings.sessionID);
  const handshake = await client.request('health', {}).then((info) => ({ ok: true, info })).catch((error) => ({ ok: false, error }));
  if (handshake.ok && handshake.info && typeof handshake.info.protocolVersion === 'number' && handshake.info.protocolVersion > 2) {
    await client.close();
    throw new Error(`Runtime protocol v${handshake.info.protocolVersion} is newer than this CLI supports (v2). Upgrade the CLI.`);
  }
  if (!handshake.ok) {
    await client.close();
    throw handshake.error;
  }
  let interrupted = false;
  let cancelTimer;
  let active = false;
  const cancel = () => {
    if (interrupted) { void client.close(); input?.close(); return; }
    interrupted = true;
    process.exitCode = 130;
    input?.close();
    if (active) void client.request('session.cancel', { sessionID: settings.sessionID }).catch(() => {});
    cancelTimer = setTimeout(() => { void client.close(); }, 1500);
  };
  process.on('SIGINT', cancel);
  input?.on('SIGINT', cancel);
  let streamed = false;
  let approval;
  let finalResult;
  let textBuffer = '';
  const tools = [];
  client.onEvent = (event) => {
    if (event.type === 'assistant_text' && typeof event.text === 'string') {
      streamed = true;
      textBuffer += event.text;
      if (!json) process.stdout.write(display(event.text));
    } else if (event.type === 'approval_required') approval = event;
    else if (event.type === 'tool_started') { tools.push({ tool: event.tool, id: event.id }); if (!json) process.stderr.write(`\n[tool] ${display(event.tool)}\n`); }
    else if (event.type === 'tool_completed' || event.type === 'tool_failed') { const t = tools.find((item) => item.id === event.id); if (t) t.ok = event.type === 'tool_completed'; }
    else if (event.type === 'model_retrying' && !json) process.stderr.write(`\n[retry ${event.attempt}/${event.maxAttempts}] ${display(event.error)}\n`);
    else if (event.type === 'recovery_attention' && !json) process.stderr.write(`\n[attention] ${display(event.message)}\n`);
  };
  async function turn(method, extra) {
    while (!interrupted) {
      streamed = false;
      approval = undefined;
      active = true;
      let result;
      try { result = await client.request(method, { ...settings, ...extra }); }
      finally { active = false; }
      finalResult = result;
      if (!json) {
        if (!streamed && typeof result?.text === 'string') process.stdout.write(display(result.text));
        if (streamed || result?.text) process.stdout.write('\n');
      }
      if (result?.status !== 'waiting_approval') {
        if (result?.status === 'cancelled') process.exitCode = 1;
        return;
      }
      if (!approval?.id) throw new Error('Runtime requested approval without an approval ID.');
      if (!input) {
        process.stderr.write(`Approval required: ${display(approval.tool)}. Resume in a terminal: deepseek session resume ${settings.sessionID}\n`);
        process.exitCode = 2;
        return;
      }
      process.stderr.write(`\nApproval: ${display(approval.tool)} (${display(approval.risk)})\n${display(approval.preview || '')}\n`);
      const answer = await question('Allow this operation? [y/N] ');
      if (interrupted) return;
      method = 'session.resolveApproval';
      extra = { approvalID: approval.id, decision: /^(y|yes)$/i.test(answer || '') ? 'allow' : 'deny' };
    }
  }
  try {
    process.stderr.write(`Session: ${settings.sessionID}\n`);
    if (pendingApproval) {
      approval = pendingApproval;
      process.stderr.write(`Pending approval: ${display(pendingApproval.tool)} (${display(pendingApproval.risk)})\n${display(JSON.stringify(pendingApproval.arguments || {}))}\n`);
      const answer = await question('Allow this operation? [y/N] ');
      if (!interrupted) await turn('session.resolveApproval', { approvalID: pendingApproval.approvalID, decision: /^(y|yes)$/i.test(answer || '') ? 'allow' : 'deny' });
    }
    if (prompt && !interrupted) await turn('session.run', { prompt });
    if (json && !interactive && !interrupted) {
      const status = finalResult?.status ?? 'unknown';
      process.stdout.write(JSON.stringify({
        sessionID: settings.sessionID,
        status,
        text: typeof finalResult?.text === 'string' ? finalResult.text : (textBuffer || null),
        delivery: finalResult?.delivery ?? null,
        tools,
        error: null
      }, null, 2) + '\n');
    }
    if (interactive) {
      process.stderr.write('DeepSeek Code · /help for commands · Ctrl+C to cancel\n');
      while (!interrupted) {
        const text = await question('\n你 > ');
        if (text === undefined || text === '/exit' || text === '/quit') break;
        if (!text) continue;
        if (text === '/help') { process.stderr.write('/exit /quit: close · /session: session ID · /mode <mode>: permissions · /help: help\nOther slash commands are sent to project skills.\n'); continue; }
        if (text === '/session') { process.stderr.write(`${settings.sessionID}\n`); continue; }
        if (text.startsWith('/mode ')) {
          const mode = text.slice(6).trim().replace('acceptEdits', 'accept_edits');
          if (!['plan', 'manual', 'accept_edits', 'auto'].includes(mode)) process.stderr.write('Mode must be plan, manual, accept_edits or auto.\n');
          else { settings.mode = mode; process.stderr.write(`Mode: ${mode}\n`); }
          continue;
        }
        await turn('session.run', { prompt: text });
      }
    }
  } catch (error) {
    if (!interrupted) throw error;
  } finally {
    clearTimeout(cancelTimer);
    process.removeListener('SIGINT', cancel);
    input?.close();
    await client.close();
  }
}