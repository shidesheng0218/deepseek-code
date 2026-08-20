/**
 * versus 驱动器共享工具：进程探测、项目复制、git 初始化、命令执行。
 * 所有驱动器与编排器只允许使用 node: 内置模块。
 */
import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const driversDir = dirname(fileURLToPath(import.meta.url));
export const versusDir = join(driversDir, '..');
export const repoRoot = join(versusDir, '..', '..');

/** 探测 CLI 是否可用（只查 PATH，不执行任何有副作用的命令）。 */
export function which(command) {
  try {
    const result = spawnSync('which', [command], { stdio: ['ignore', 'pipe', 'ignore'] });
    return result.status === 0;
  } catch {
    return false;
  }
}

/** 把语料项目复制到独立工作目录，保证各家 harness 互不污染。 */
export function materializeProject(projectDir) {
  const workDir = mkdtempSync(join(tmpdir(), 'deepseek-versus-'));
  cpSync(projectDir, workDir, { recursive: true });
  return workDir;
}

/** 语料项目初始化为 git 仓库，让 inspect_git / review 类能力表现与真实项目一致。 */
export function gitInit(workDir) {
  const options = { cwd: workDir, stdio: ['ignore', 'ignore', 'ignore'] };
  try {
    spawnSync('git', ['init', '-q'], options);
    spawnSync('git', ['add', '-A'], options);
    spawnSync('git', ['-c', 'user.email=versus@bench.local', '-c', 'user.name=versus', 'commit', '-qm', 'corpus baseline'], options);
  } catch {
    // 无 git 的环境降级为普通目录；验证命令不依赖 git。
  }
}

/**
 * 在工作目录执行 shell 命令（用于 verify），带超时。
 * @returns {Promise<{ exitCode: number|null, stdout: string, stderr: string, timedOut: boolean, wallMs: number }>}
 */
export function runCommand(command, cwd, timeoutMs = 120_000) {
  const started = Date.now();
  return new Promise((resolvePromise) => {
    const child = spawn(command, { cwd, shell: true, stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', (error) => {
      clearTimeout(timer);
      resolvePromise({ exitCode: null, stdout, stderr: `${stderr}${error instanceof Error ? error.message : String(error)}`, timedOut, wallMs: Date.now() - started });
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      resolvePromise({ exitCode: code, stdout: stdout.slice(-20_000), stderr: stderr.slice(-20_000), timedOut, wallMs: Date.now() - started });
    });
  });
}

/** 以流式方式收集子进程输出，回调逐行（JSONL 驱动器用）。 */
export function spawnLines(command, args, options, onLine) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { ...options, stdio: ['ignore', 'pipe', 'pipe'] });
    let buffer = '';
    let stderr = '';
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, options.timeoutMs ?? 300_000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) if (line.trim()) onLine(line);
    });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', (error) => {
      clearTimeout(timer);
      resolvePromise({ exitCode: null, stderr: String(error?.message ?? error), tail: buffer, timedOut });
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      if (buffer.trim()) onLine(buffer);
      resolvePromise({ exitCode: code, stderr: stderr.slice(-10_000), timedOut });
    });
  });
}

export function ensureDir(path) {
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
}

/**
 * 解析 versus.config.json 里某个 harness 的 env 映射：
 * 以 "$" 开头的值引用进程环境变量（密钥只从环境读取，绝不写进配置文件），
 * 其余按字面量传递。返回 { env, missing }，missing 非空时应跳过该 harness。
 */
export function resolveEnv(model) {
  const env = {};
  const missing = [];
  for (const [key, value] of Object.entries(model?.env ?? {})) {
    if (typeof value === 'string' && value.startsWith('$')) {
      const name = value.slice(1);
      if (process.env[name]) env[key] = process.env[name];
      else missing.push(name);
    } else {
      env[key] = String(value);
    }
  }
  return { env, missing };
}
