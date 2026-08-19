import { execFile as execFileCallback } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

/**
 * 生命周期 Hooks：用户在设置文件中声明的 shell 命令，在关键节点执行。
 *
 * 配置位置（后者覆盖/补充前者，均为可选）：
 *   ~/.deepseek/settings.json
 *   <project>/.deepseek/settings.json
 *   <project>/.claude/settings.json 与 .claude/settings.local.json（兼容读取）
 *
 * 形状：
 *   { "hooks": { "preToolUse": "cmd", "postToolUse": ["cmd1", "cmd2"],
 *                "sessionStart": "cmd", "userPromptSubmit": "cmd" } }
 * 兼容 Claude 风格的 { "PreToolUse": [{ "command": "cmd" }] } 写法。
 *
 * 协议：命令通过 stdin 收到 JSON 负载；退出码 2 或 stdout JSON
 * {"decision":"block","reason":"..."} 表示阻止（仅 preToolUse /
 * userPromptSubmit 有意义）。Hook 输出写入事件日志，不进入模型上下文。
 * Hook 负载不含 API Key 等密钥；命令在 10 秒后超时。
 */

export type HookKind = 'preToolUse' | 'postToolUse' | 'sessionStart' | 'userPromptSubmit';
export type HookMap = Record<HookKind, string[]>;

export interface HookResult {
  blocked?: string;
  outputs: Array<{ command: string; stdout: string; stderr: string; exitCode: number }>;
}

const HOOK_KINDS: HookKind[] = ['preToolUse', 'postToolUse', 'sessionStart', 'userPromptSubmit'];

function emptyHookMap(): HookMap {
  return { preToolUse: [], postToolUse: [], sessionStart: [], userPromptSubmit: [] };
}

function normalizeCommands(value: unknown): string[] {
  if (typeof value === 'string') return value.trim() ? [value] : [];
  if (Array.isArray(value)) {
    return value.flatMap((entry) => {
      if (typeof entry === 'string') return entry.trim() ? [entry] : [];
      if (entry && typeof entry === 'object' && typeof (entry as Record<string, unknown>).command === 'string') {
        const command = (entry as Record<string, unknown>).command as string;
        return command.trim() ? [command] : [];
      }
      return [];
    });
  }
  if (value && typeof value === 'object' && typeof (value as Record<string, unknown>).command === 'string') {
    const command = (value as Record<string, unknown>).command as string;
    return command.trim() ? [command] : [];
  }
  return [];
}

function extractHooks(settings: Record<string, unknown>): Partial<Record<HookKind, string[]>> {
  const hooks = settings.hooks;
  if (!hooks || typeof hooks !== 'object') return {};
  const record = hooks as Record<string, unknown>;
  const aliases: Record<string, HookKind> = {
    preToolUse: 'preToolUse', PreToolUse: 'preToolUse',
    postToolUse: 'postToolUse', PostToolUse: 'postToolUse',
    sessionStart: 'sessionStart', SessionStart: 'sessionStart',
    userPromptSubmit: 'userPromptSubmit', UserPromptSubmit: 'userPromptSubmit'
  };
  const found: Partial<Record<HookKind, string[]>> = {};
  for (const [key, kind] of Object.entries(aliases)) {
    const commands = normalizeCommands(record[key]);
    if (commands.length > 0) found[kind] = [...(found[kind] ?? []), ...commands];
  }
  return found;
}

async function readSettingsFile(path: string): Promise<Record<string, unknown>> {
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

export async function loadHooks(projectPath: string, home: string = process.env.HOME ?? '.'): Promise<HookMap> {
  const files = [
    join(home, '.deepseek', 'settings.json'),
    join(projectPath, '.deepseek', 'settings.json'),
    join(projectPath, '.claude', 'settings.json'),
    join(projectPath, '.claude', 'settings.local.json')
  ];
  const merged = emptyHookMap();
  for (const file of files) {
    const hooks = extractHooks(await readSettingsFile(file));
    for (const kind of HOOK_KINDS) merged[kind].push(...(hooks[kind] ?? []));
  }
  return merged;
}

export function mergeHookMaps(...maps: HookMap[]): HookMap {
  const merged = emptyHookMap();
  for (const map of maps) for (const kind of HOOK_KINDS) merged[kind].push(...map[kind]);
  return merged;
}

export function hasHooks(map: HookMap): boolean {
  return HOOK_KINDS.some((kind) => map[kind].length > 0);
}

interface HookProcessResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

function execHook(command: string, stdin: string, cwd: string, kind: HookKind, shell: { file: string; args: string[] }): Promise<HookProcessResult> {
  return new Promise((resolvePromise) => {
    const child = execFileCallback(
      shell.file,
      [...shell.args, command],
      {
        cwd,
        timeout: 10_000,
        maxBuffer: 200_000,
        env: {
          PATH: process.env.PATH ?? '/usr/bin:/bin:/usr/local/bin',
          HOME: process.env.HOME ?? '',
          DEEPSEEK_HOOK_KIND: kind
        }
      },
      (error, stdout, stderr) => {
        const failure = error as { code?: number | string } | null;
        resolvePromise({
          stdout: (stdout ?? '').slice(0, 4_000),
          stderr: (stderr ?? '').slice(0, 4_000),
          exitCode: typeof failure?.code === 'number' ? failure.code : failure ? 1 : 0
        });
      }
    );
    child.stdin?.on('error', () => undefined);
    child.stdin?.end(stdin);
  });
}

export async function runHook(
  commands: string[],
  kind: HookKind,
  payload: Record<string, unknown>,
  cwd: string,
  shell: { file: string; args: string[] } = { file: '/bin/sh', args: ['-lc'] }
): Promise<HookResult> {
  const result: HookResult = { outputs: [] };
  for (const command of commands.slice(0, 8)) {
    const { stdout, stderr, exitCode } = await execHook(command, JSON.stringify({ hook: kind, ...payload }), cwd, kind, shell);
    result.outputs.push({ command, stdout, stderr, exitCode });
    if (exitCode === 2) {
      result.blocked = stderr.trim() || `Hook 阻止了该操作（${kind}）`;
      return result;
    }
    try {
      const parsed = JSON.parse(stdout.trim());
      if (parsed && parsed.decision === 'block') {
        result.blocked = typeof parsed.reason === 'string' && parsed.reason.trim() ? parsed.reason : `Hook 阻止了该操作（${kind}）`;
        return result;
      }
    } catch {
      // stdout 不是 JSON 时视为普通输出。
    }
  }
  return result;
}
