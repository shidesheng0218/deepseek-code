import { describe, expect, test } from 'vitest';
import { browserExecutableCandidates } from '../../src/core/playwright-launcher';

describe('playwright launcher resource discovery', () => {
  test('checks the bundled Tauri browser resource next to the sidecar executable', () => {
    expect(browserExecutableCandidates('/Applications/DeepSeek Code.app/Contents/MacOS/deepseek-agent-runtime')).toContain(
      '/Applications/DeepSeek Code.app/Contents/Resources/browser/chrome-headless-shell'
    );
  });
});
