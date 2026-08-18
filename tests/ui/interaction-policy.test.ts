import { describe, expect, test } from 'vitest';
import { canSubmitTask, shouldRenderFrame, submitActionLabel } from '../../apps/deepseek-code-desktop/src/interaction-policy';

describe('desktop interaction policy', () => {
  test('allows a non-empty follow-up message while the same session is running', () => {
    expect(canSubmitTask({ runtimeReady: true, busy: true, text: '补充检查错误日志', apiKey: 'key', projectPath: '/workspace' })).toBe(true);
    expect(submitActionLabel(true)).toBe('追加消息');
  });

  test('still blocks a blank message or missing runtime configuration', () => {
    expect(canSubmitTask({ runtimeReady: true, busy: true, text: '   ', apiKey: 'key', projectPath: '/workspace' })).toBe(false);
    expect(canSubmitTask({ runtimeReady: false, busy: false, text: 'hello', apiKey: 'key', projectPath: '/workspace' })).toBe(false);
    expect(canSubmitTask({ runtimeReady: true, busy: false, text: 'hello', apiKey: '', projectPath: '/workspace' })).toBe(false);
  });

  test('renders each stable runtime frame ID at most once', () => {
    const seen = new Set<string>();
    expect(shouldRenderFrame('event-1', seen)).toBe(true);
    expect(shouldRenderFrame('event-1', seen)).toBe(false);
    expect(shouldRenderFrame('event-2', seen)).toBe(true);
  });
});
