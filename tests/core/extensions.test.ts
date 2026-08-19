import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { loadExtensions } from '../../src/core/extensions';
import { AgentRuntime } from '../../src/core/agent-runtime';
import { ToolExecutionPipeline } from '../../src/core/tool-execution-pipeline';

async function writeExtension(root: string, name: string, source: string): Promise<void> {
  const dir = join(root, '.deepseek', 'extensions');
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, name), source);
}

describe('extensions', () => {
  test('loads extension tools into the ext__ namespace with schemas', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-ext-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-ext-home-'));
    await writeExtension(project, 'word-count.mjs', `
      export default function setup(ctx) {
        ctx.registerTool('word_count', async ({ text }) => ({ count: String(text ?? '').split(/\\s+/).filter(Boolean).length }), { mutates: false, description: '统计词数' })
      }
    `);
    const loaded = await loadExtensions(project, home);
    expect(loaded.names).toHaveLength(1);
    expect(loaded.warnings).toEqual([]);
    expect(Object.keys(loaded.tools)).toEqual(['ext__word_count']);
    expect(loaded.definitions.ext__word_count?.mutates).toBe(false);
    expect(loaded.schemas[0]?.function.name).toBe('ext__word_count');
    await expect(loaded.tools['ext__word_count']?.({ text: 'hello world' })).resolves.toEqual({ count: 2 });
  });

  test('a broken extension produces a warning and never breaks others', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-ext-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-ext-home-'));
    await writeExtension(project, 'a-broken.mjs', 'throw new Error("boom")');
    await writeExtension(project, 'b-good.mjs', 'export default (ctx) => ctx.registerTool("ok", async () => "fine", { mutates: false })');
    const loaded = await loadExtensions(project, home);
    expect(loaded.warnings.some((warning) => warning.includes('boom'))).toBe(true);
    expect(loaded.tools.ext__ok).toBeDefined();
  });

  test('modules without a setup export are skipped with a warning', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-ext-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-ext-home-'));
    await writeExtension(project, 'plain.mjs', 'export const value = 1');
    const loaded = await loadExtensions(project, home);
    expect(loaded.names).toEqual([]);
    expect(loaded.warnings.some((warning) => warning.includes('setup'))).toBe(true);
  });

  test('extension tools still flow through pipeline permissions and events', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-ext-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-ext-home-'));
    await writeExtension(project, 'writer.mjs', 'export default (ctx) => ctx.registerTool("write_file", async () => ({ wrote: true }), { mutates: true })');
    const loaded = await loadExtensions(project, home);

    const events: string[] = [];
    const pipeline = new ToolExecutionPipeline({
      runtime: new AgentRuntime({ sessionId: 's1', mode: 'manual' }),
      tools: loaded.tools,
      definitions: loaded.definitions,
      onEvent: (event) => events.push(event.type)
    });
    // manual 模式下变更类工具必须进入审批，而不是直接执行
    const outcome = await pipeline.execute({ id: 'c1', tool: 'ext__write_file', arguments: {} });
    expect(outcome.state).toBe('awaitingApproval');
    expect(events).toContain('approval_required');
  });

  test('extension hooks and event listeners are collected', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-ext-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-ext-home-'));
    await writeExtension(project, 'observe.mjs', `
      export default function setup(ctx) {
        ctx.registerHook('postToolUse', 'echo done')
        ctx.onEvent((event) => globalThis.__seen = (globalThis.__seen || 0) + 1)
      }
    `);
    const loaded = await loadExtensions(project, home);
    expect(loaded.hooks.postToolUse).toEqual(['echo done']);
    expect(loaded.listeners).toHaveLength(1);
    (globalThis as Record<string, unknown>).__seen = 0;
    loaded.listeners[0]?.({});
    expect((globalThis as Record<string, unknown>).__seen).toBe(1);
    delete (globalThis as Record<string, unknown>).__seen;
  });
});
