import { describe, expect, it } from 'vitest';
import { canSubmitTask, shouldRenderFrame, submitActionLabel } from './interaction-policy';

describe('canSubmitTask', () => {
  const base = { runtimeReady: true, busy: false, text: 'fix the bug', apiKey: 'sk-test', projectPath: '/tmp/project' };

  it('allows submission when every field is present and the runtime is ready', () => {
    expect(canSubmitTask(base)).toBe(true);
  });

  it('blocks submission when the runtime is not ready', () => {
    expect(canSubmitTask({ ...base, runtimeReady: false })).toBe(false);
  });

  it('blocks submission when the prompt is empty or whitespace-only', () => {
    expect(canSubmitTask({ ...base, text: '' })).toBe(false);
    expect(canSubmitTask({ ...base, text: '   ' })).toBe(false);
  });

  it('blocks submission when the API key is missing (this is the "先选项目/先配 key" gate)', () => {
    expect(canSubmitTask({ ...base, apiKey: '' })).toBe(false);
  });

  it('blocks submission when the project directory is missing', () => {
    expect(canSubmitTask({ ...base, projectPath: '' })).toBe(false);
    expect(canSubmitTask({ ...base, projectPath: '   ' })).toBe(false);
  });

  it('does not block on busy alone — busy sessions can still queue a follow-up message', () => {
    expect(canSubmitTask({ ...base, busy: true })).toBe(true);
  });
});

describe('submitActionLabel', () => {
  it('reads "开始任务" for a fresh session', () => {
    expect(submitActionLabel(false)).toBe('开始任务');
  });

  it('reads "追加消息" while the agent is busy, so a second submit queues rather than restarts', () => {
    expect(submitActionLabel(true)).toBe('追加消息');
  });
});

describe('shouldRenderFrame', () => {
  it('renders a frame with no id (some runtime frames omit it)', () => {
    expect(shouldRenderFrame('', new Set())).toBe(true);
  });

  it('renders the first time a given frame id is seen', () => {
    const seen = new Set<string>();
    expect(shouldRenderFrame('frame-1', seen)).toBe(true);
  });

  it('deduplicates a frame id seen twice — sidecar reconnects can replay the same frame', () => {
    const seen = new Set<string>();
    expect(shouldRenderFrame('frame-1', seen)).toBe(true);
    expect(shouldRenderFrame('frame-1', seen)).toBe(false);
  });

  it('tracks distinct ids independently', () => {
    const seen = new Set<string>();
    expect(shouldRenderFrame('frame-1', seen)).toBe(true);
    expect(shouldRenderFrame('frame-2', seen)).toBe(true);
    expect(shouldRenderFrame('frame-1', seen)).toBe(false);
    expect(shouldRenderFrame('frame-2', seen)).toBe(false);
  });
});
