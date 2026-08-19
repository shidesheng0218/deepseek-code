import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { hasHooks, loadHooks, mergeHookMaps, runHook } from '../../src/core/hooks';

describe('hooks', () => {
  test('loads hooks from user, project and claude-compatible settings', async () => {
    const project = await mkdtemp(join(tmpdir(), 'deepseek-hooks-project-'));
    const home = await mkdtemp(join(tmpdir(), 'deepseek-hooks-home-'));
    await mkdir(join(home, '.deepseek'), { recursive: true });
    await writeFile(join(home, '.deepseek', 'settings.json'), JSON.stringify({ hooks: { preToolUse: 'echo user' } }));
    await mkdir(join(project, '.deepseek'), { recursive: true });
    await writeFile(join(project, '.deepseek', 'settings.json'), JSON.stringify({ hooks: { preToolUse: ['echo project'], postToolUse: 'echo post' } }));
    await mkdir(join(project, '.claude'), { recursive: true });
    await writeFile(join(project, '.claude', 'settings.json'), JSON.stringify({ hooks: { PreToolUse: [{ command: 'echo claude' }] } }));

    const hooks = await loadHooks(project, home);
    expect(hooks.preToolUse).toEqual(['echo user', 'echo project', 'echo claude']);
    expect(hooks.postToolUse).toEqual(['echo post']);
    expect(hasHooks(hooks)).toBe(true);
  });

  test('runs hooks with JSON payload on stdin and captures output', async () => {
    const cwd = await mkdtemp(join(tmpdir(), 'deepseek-hooks-cwd-'));
    const result = await runHook(['cat 1>&2'], 'preToolUse', { tool: 'run_command' }, cwd);
    expect(result.blocked).toBeUndefined();
    expect(result.outputs).toHaveLength(1);
    expect(result.outputs[0]?.exitCode).toBe(0);
    expect(result.outputs[0]?.stderr).toContain('preToolUse');
    expect(result.outputs[0]?.stderr).toContain('run_command');
  });

  test('blocks on exit code 2 with stderr as the reason', async () => {
    const cwd = await mkdtemp(join(tmpdir(), 'deepseek-hooks-cwd-'));
    const result = await runHook(['echo "不允许" 1>&2; exit 2'], 'preToolUse', {}, cwd);
    expect(result.blocked).toBe('不允许');
  });

  test('blocks on JSON decision in stdout', async () => {
    const cwd = await mkdtemp(join(tmpdir(), 'deepseek-hooks-cwd-'));
    const result = await runHook(['echo \'{"decision":"block","reason":"策略拒绝"}\''], 'userPromptSubmit', {}, cwd);
    expect(result.blocked).toBe('策略拒绝');
  });

  test('hook payload never receives provider credentials', async () => {
    const cwd = await mkdtemp(join(tmpdir(), 'deepseek-hooks-cwd-'));
    const env = { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '' };
    const result = await runHook(['env'], 'sessionStart', { sessionID: 's1' }, cwd);
    expect(result.outputs[0]?.stdout).not.toContain('DEEPSEEK_API_KEY');
    expect(Object.keys(env)).not.toContain('DEEPSEEK_API_KEY');
  });

  test('mergeHookMaps concatenates each kind', () => {
    const merged = mergeHookMaps(
      { preToolUse: ['a'], postToolUse: [], sessionStart: [], userPromptSubmit: [] },
      { preToolUse: ['b'], postToolUse: ['c'], sessionStart: [], userPromptSubmit: [] }
    );
    expect(merged.preToolUse).toEqual(['a', 'b']);
    expect(merged.postToolUse).toEqual(['c']);
  });
});
