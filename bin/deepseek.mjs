#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const runtime = process.env.DEEPSEEK_RUNTIME_BINARY || join(root, 'apps/deepseek-agent-runtime/dist/deepseek-agent-runtime');
const sessionsRoot = process.env.DEEPSEEK_SESSION_ROOT || join(process.env.HOME || '.', 'Library/Application Support/DeepSeekCode/sessions');

function usage() {
  process.stderr.write('Usage: deepseek doctor | ask <prompt> | run <prompt> | session list | session attach <id> | session resume <id>\n');
  process.exit(2);
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
  else usage();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
