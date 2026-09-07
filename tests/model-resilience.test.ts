import { describe, expect, it } from 'vitest';
import { ModelRequestError, describeModelError, httpError, isRetryableModelError, mergedStreamSignal, MODEL_STREAM_TIMEOUT_MS } from '../src/core/providers/model-errors';
import { streamWithRetry } from '../src/core/providers/stream-retry';
import { estimateUsageCost, pricingForModel } from '../src/core/usage';

describe('httpError / isRetryableModelError', () => {
  it('marks 429 and 5xx as retryable', () => {
    for (const status of [408, 429, 500, 502, 503, 504]) {
      expect(isRetryableModelError(httpError(status, 'x'))).toBe(true);
    }
  });

  it('marks auth and client errors as non-retryable', () => {
    for (const status of [400, 401, 402, 403, 404]) {
      expect(isRetryableModelError(httpError(status, 'x'))).toBe(false);
    }
  });

  it('rejects non-model errors', () => {
    expect(isRetryableModelError(new Error('boom'))).toBe(false);
    expect(isRetryableModelError('boom')).toBe(false);
  });
});

describe('describeModelError', () => {
  it('gives an actionable hint for 401', () => {
    expect(describeModelError(httpError(401, 'invalid key'))).toContain('API Key');
  });

  it('gives an actionable hint for 429', () => {
    expect(describeModelError(httpError(429, 'rate limited'))).toContain('限流');
  });

  it('gives an actionable hint for timeouts', () => {
    const error = new ModelRequestError('timed out', 'timeout', true);
    expect(describeModelError(error)).toContain('超时');
  });

  it('explains malformed tool arguments as a safe abort', () => {
    const error = new ModelRequestError('bad json', 'malformed_tool_arguments', false);
    expect(describeModelError(error)).toContain('安全中止');
    expect(isRetryableModelError(error)).toBe(false);
  });

  it('passes through non-model errors unchanged', () => {
    expect(describeModelError(new Error('plain failure'))).toBe('plain failure');
  });
});

describe('mergedStreamSignal', () => {
  it('stays silent when nothing happens', () => {
    const { signal, isTimeout } = mergedStreamSignal(undefined, 10_000);
    expect(signal.aborted).toBe(false);
    expect(isTimeout()).toBe(false);
    signal.dispatchEvent(new Event('abort'));
  });

  it('propagates user cancellation without marking a timeout', () => {
    const user = new AbortController();
    const { signal, isTimeout } = mergedStreamSignal(user.signal, 10_000);
    user.abort();
    expect(signal.aborted).toBe(true);
    expect(isTimeout()).toBe(false);
  });

  it('aborts on timeout and marks it', async () => {
    const { signal, isTimeout } = mergedStreamSignal(undefined, 10);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(signal.aborted).toBe(true);
    expect(isTimeout()).toBe(true);
  });

  it('has a sane overall stream timeout', () => {
    expect(MODEL_STREAM_TIMEOUT_MS).toBeGreaterThanOrEqual(120_000);
  });
});

async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const events: T[] = [];
  for await (const event of stream) events.push(event);
  return events;
}

describe('streamWithRetry', () => {
  const retryable = (error: unknown): boolean => error instanceof ModelRequestError && error.retryable;

  it('retries a retryable failure before the first event', async () => {
    let calls = 0;
    const events = await collect(streamWithRetry(
      () => (async function* () {
        calls += 1;
        if (calls < 3) throw httpError(429, 'rate limited');
        yield 'ok';
      })(),
      retryable,
      { sleep: () => Promise.resolve() }
    ));
    expect(events).toEqual(['ok']);
    expect(calls).toBe(3);
  });

  it('does not retry a non-retryable failure', async () => {
    let calls = 0;
    await expect(collect(streamWithRetry(
      () => (async function* () {
        calls += 1;
        if (calls > 0) throw httpError(401, 'invalid key');
        yield 'never';
      })(),
      retryable,
      { sleep: () => Promise.resolve() }
    ))).rejects.toThrow('401');
    expect(calls).toBe(1);
  });

  it('never retries once an event has been yielded', async () => {
    let calls = 0;
    await expect(collect(streamWithRetry(
      () => (async function* () {
        calls += 1;
        yield 'partial';
        throw httpError(500, 'server blew up mid-stream');
      })(),
      retryable,
      { sleep: () => Promise.resolve() }
    ))).rejects.toThrow('500');
    expect(calls).toBe(1);
  });

  it('gives up after maxAttempts and reports each retry', async () => {
    let calls = 0;
    const retries: number[] = [];
    await expect(collect(streamWithRetry(
      () => (async function* () {
        calls += 1;
        if (calls > 0) throw httpError(503, 'unavailable');
        yield 'never';
      })(),
      retryable,
      { maxAttempts: 3, sleep: () => Promise.resolve(), onRetry: (attempt) => retries.push(attempt) }
    ))).rejects.toThrow('503');
    expect(calls).toBe(3);
    expect(retries).toEqual([1, 2]);
  });

  it('passes through a normal multi-event stream untouched', async () => {
    const events = await collect(streamWithRetry(
      () => (async function* () {
        yield 'a';
        yield 'b';
      })(),
      retryable
    ));
    expect(events).toEqual(['a', 'b']);
  });
});

describe('pricingForModel / estimateUsageCost', () => {
  it('knows DeepSeek list prices and ignores unknown models', () => {
    expect(pricingForModel('deepseek-chat')).toBeDefined();
    expect(pricingForModel('DeepSeek-Chat')).toBeDefined();
    expect(pricingForModel('some-other-model')).toBeUndefined();
  });

  it('does not double-count cached input tokens', () => {
    const pricing = pricingForModel('deepseek-chat')!;
    const cost = estimateUsageCost(pricing, { inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 0 });
    // 600k 未命中按峰时价 $0.44/M，400k 命中按峰时价 $0.014/M，而不是 1M 全价 + 400k 缓存价。
    expect(cost).toBeCloseTo(0.6 * 0.44 + 0.4 * 0.014, 6);
  });
});
