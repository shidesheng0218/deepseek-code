import { describe, expect, test } from 'vitest';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { aggregate, costForTokens, median, normalizeResult, tokensTotal, type VersusResult } from '../../benchmarks/versus/harvest.mjs';
import { resolveEnv } from '../../benchmarks/versus/drivers/util.mjs';

function result(overrides: Partial<VersusResult>): VersusResult {
  return {
    taskID: 'vs-000', harness: 'deepseek', runIndex: 1, startedAt: '2026-08-20T00:00:00.000Z', wallMs: 1000,
    status: 'completed', error: null, verify: { command: 'npm test', exitCode: 0, timedOut: false }, success: true,
    approvals: 0, tokens: { input: 100, output: 50, cached: 10 }, costUSD: null, transcriptFile: null,
    ...overrides
  };
}

describe('versus harvest', () => {
  test('median 处理奇偶与空集', () => {
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([])).toBeNull();
    expect(median([undefined, 5])).toBe(5);
  });

  test('tokensTotal 与 costForTokens 按价格表换算', () => {
    expect(tokensTotal(null)).toBeNull();
    expect(tokensTotal({ input: 100, output: 50, cached: 10 })).toBe(150);
    const cost = costForTokens({ input: 1_000_000, output: 1_000_000, cached: 1_000_000 }, { input: 3, output: 15, cachedInput: 0.3 });
    expect(cost).toBeCloseTo(18.3, 5);
    expect(costForTokens(null, { input: 3 })).toBeNull();
    expect(costForTokens({ input: 1, output: 1, cached: 0 }, null)).toBeNull();
  });

  test('normalizeResult 在无上报成本时按价格表回填', () => {
    const normalized = normalizeResult(result({ costUSD: null }), { input: 1, output: 1, cachedInput: 0 });
    expect(normalized.totalTokens).toBe(150);
    expect(normalized.costUSD).toBeCloseTo(0.00015, 8);
  });

  test('aggregate 计算成功率、均摊成本与度量覆盖', () => {
    const stats = aggregate([
      result({ harness: 'deepseek', success: true, approvals: 1, costUSD: 0.02 }),
      result({ harness: 'deepseek', success: false, verify: { command: 'npm test', exitCode: 1, timedOut: false }, approvals: 2, costUSD: 0.02 }),
      result({ harness: 'claude-code', success: true, approvals: null, tokens: null, costUSD: 0.06 }),
      result({ harness: 'claude-code', status: 'error', error: 'boom', success: false, verify: null, tokens: null, costUSD: null, approvals: null })
    ]);
    const deepseek = stats.find((row) => row.harness === 'deepseek');
    const claude = stats.find((row) => row.harness === 'claude-code');
    expect(deepseek?.successRate).toBe(0.5);
    expect(deepseek?.avgApprovals).toBe(1.5);
    expect(deepseek?.costPerSolvedUSD).toBeCloseTo(0.04, 8);
    expect(deepseek?.tokensPerSolved).toBe(300);
    expect(deepseek?.coverage.tokens).toBe(1);
    expect(claude?.errors).toBe(1);
    expect(claude?.coverage.tokens).toBe(0);
    expect(claude?.coverage.approvals).toBe(0);
    expect(claude?.costPerSolvedUSD).toBeCloseTo(0.06, 8);
  });

  test('aggregate 对零成功与全缺数据保持 null 而不是 NaN', () => {
    const stats = aggregate([result({ success: false, tokens: null, costUSD: null, approvals: null })]);
    expect(stats[0]?.costPerSolvedUSD).toBeNull();
    expect(stats[0]?.tokensPerSolved).toBeNull();
    expect(stats[0]?.avgApprovals).toBeNull();
    expect(stats[0]?.medianWallMs).toBe(1000);
  });
});

describe('versus env 解析（密钥只从环境变量读取）', () => {
  test('字面量透传、$ 引用解析、缺失变量进 missing', () => {
    process.env.VS_TEST_SECRET = 'sk-test';
    try {
      const resolved = resolveEnv({
        env: {
          ANTHROPIC_BASE_URL: 'https://api.moonshot.cn/anthropic',
          ANTHROPIC_AUTH_TOKEN: '$VS_TEST_SECRET',
          MISSING_TOKEN: '$VS_TEST_NOT_SET'
        }
      });
      expect(resolved.env.ANTHROPIC_BASE_URL).toBe('https://api.moonshot.cn/anthropic');
      expect(resolved.env.ANTHROPIC_AUTH_TOKEN).toBe('sk-test');
      expect(resolved.env.MISSING_TOKEN).toBeUndefined();
      expect(resolved.missing).toEqual(['VS_TEST_NOT_SET']);
    } finally {
      delete process.env.VS_TEST_SECRET;
    }
  });

  test('空配置返回空 env 与空 missing', () => {
    expect(resolveEnv(null)).toEqual({ env: {}, missing: [] });
    expect(resolveEnv({})).toEqual({ env: {}, missing: [] });
  });
});

describe('versus 语料完整性（离线静态校验）', () => {
  const corpusDir = join(process.cwd(), 'benchmarks', 'versus', 'corpus');
  const taskFiles = readdirSync(corpusDir).filter((name) => name.endsWith('.json'));

  test('至少包含起步语料 4 题', () => {
    expect(taskFiles.length).toBeGreaterThanOrEqual(4);
  });

  for (const name of taskFiles) {
    test(`${name}：结构齐全且夹具项目可用`, () => {
      const task = JSON.parse(readFileSync(join(corpusDir, name), 'utf8')) as {
        id: string; project: string; prompt: string;
        verify?: { command?: string; expectExitCode?: number };
        expect?: { pristineFails?: boolean };
      };
      expect(task.id).toMatch(/^vs-/);
      expect(task.prompt.length).toBeGreaterThan(10);
      expect(task.verify?.command).toBeTruthy();
      expect(typeof task.expect?.pristineFails).toBe('boolean');
      const projectDir = join(corpusDir, task.project);
      expect(existsSync(join(projectDir, 'package.json'))).toBe(true);
    });
  }
});
