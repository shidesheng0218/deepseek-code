import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { ToolDefinition } from './tool-execution-pipeline';
import type { HookKind, HookMap } from './hooks';

/**
 * 运行时扩展：本地受信的 TS/JS 模块，在 Sidecar 启动每次运行时动态加载。
 *
 * 扫描位置（均为可选）：
 *   <project>/.deepseek/extensions/*.{ts,mjs,js}
 *   ~/.deepseek/extensions/*.{ts,mjs,js}
 *
 * 模块导出默认函数或命名 `setup` 函数：
 *   export default function setup(ctx) {
 *     ctx.registerTool('word_count', async ({ text }) => ({ count: ... }), { mutates: false })
 *     ctx.registerHook('postToolUse', 'echo done >> /tmp/log')
 *     ctx.onEvent((event) => ...)
 *   }
 *
 * 边界：
 * - 扩展注册的工具以 ext__<name> 命名空间进入工具表，仍受 ToolExecutionPipeline
 *   的 schema 校验、权限分级、审批与超时约束，扩展不能绕过审批。
 * - 扩展是本地受信代码（与编辑器插件同级），在 Sidecar 进程内执行；
 *   失败的扩展只产生 warning，不影响其他扩展与主流程。
 * - 每次运行重新加载，磁盘上的修改即刻生效（热加载）。
 */

export interface ExtensionToolSpec {
  handler: (input: Record<string, unknown>) => Promise<unknown>;
  definition: ToolDefinition;
  description: string;
}

export interface ExtensionContext {
  registerTool(name: string, handler: ExtensionToolSpec['handler'], options?: { mutates?: boolean; description?: string; timeoutMs?: number }): void;
  registerHook(kind: HookKind, command: string): void;
  onEvent(listener: (event: unknown) => void): void;
  log(message: string): void;
}

export interface LoadedExtensions {
  names: string[];
  tools: Record<string, ExtensionToolSpec['handler']>;
  definitions: Record<string, ToolDefinition>;
  schemas: Array<{ type: 'function'; function: { name: string; description: string; parameters: Record<string, unknown> } }>;
  hooks: HookMap;
  listeners: Array<(event: unknown) => void>;
  warnings: string[];
}

type ExtensionModule = { default?: unknown; setup?: unknown };

async function listExtensionFiles(dir: string): Promise<string[]> {
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    return entries
      .filter((entry) => entry.isFile() && /\.(ts|mts|mjs|js)$/.test(entry.name) && !entry.name.startsWith('.'))
      .map((entry) => join(dir, entry.name))
      .sort();
  } catch {
    return [];
  }
}

export async function loadExtensions(projectPath: string, home: string = process.env.HOME ?? '.'): Promise<LoadedExtensions> {
  const loaded: LoadedExtensions = {
    names: [],
    tools: {},
    definitions: {},
    schemas: [],
    hooks: { preToolUse: [], postToolUse: [], sessionStart: [], userPromptSubmit: [] },
    listeners: [],
    warnings: []
  };

  const files = [
    ...await listExtensionFiles(join(home, '.deepseek', 'extensions')),
    ...await listExtensionFiles(join(projectPath, '.deepseek', 'extensions'))
  ];

  for (const file of files) {
    try {
      const module = await import(pathToFileURL(file).href) as ExtensionModule;
      const setup = typeof module.default === 'function' ? module.default : typeof module.setup === 'function' ? module.setup : undefined;
      if (!setup) {
        loaded.warnings.push(`扩展 ${file} 未导出 setup 函数，已跳过`);
        continue;
      }
      const context: ExtensionContext = {
        registerTool(name, handler, options) {
          if (!/^[a-z0-9][a-z0-9_]*$/i.test(name)) {
            loaded.warnings.push(`扩展 ${file} 的工具名 ${name} 不合法，已跳过`);
            return;
          }
          const fullName = `ext__${name}`;
          loaded.tools[fullName] = handler;
          loaded.definitions[fullName] = {
            name: fullName,
            mutates: options?.mutates ?? true,
            timeoutMs: options?.timeoutMs ?? 60_000
          };
          loaded.schemas.push({
            type: 'function',
            function: {
              name: fullName,
              description: options?.description ?? `扩展工具 ${name}`,
              parameters: { type: 'object', properties: {}, additionalProperties: true }
            }
          });
        },
        registerHook(kind, command) {
          if (kind in loaded.hooks && typeof command === 'string' && command.trim()) loaded.hooks[kind].push(command);
        },
        onEvent(listener) {
          if (typeof listener === 'function') loaded.listeners.push(listener);
        },
        log(message) {
          loaded.warnings.push(`[${file}] ${String(message).slice(0, 500)}`);
        }
      };
      await setup(context);
      loaded.names.push(file);
    } catch (error) {
      loaded.warnings.push(`扩展 ${file} 加载失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return loaded;
}
