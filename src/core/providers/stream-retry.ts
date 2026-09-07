import { isRetryableModelError } from './model-errors';

export interface StreamRetryOptions {
  /** 总尝试次数（含首次），默认 3，即最多自动重试 2 次。 */
  maxAttempts?: number;
  /** 首次重试前的等待毫秒数，之后按 attempt 线性放大，默认 1000。 */
  baseDelayMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /** 每次发起重试前回调（attempt 从 1 开始计数失败次数）。 */
  onRetry?: (attempt: number, error: unknown) => void;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * 为模型流式响应提供有限自动重试。
 *
 * 安全边界：只有在**尚未产出任何事件**（即连接建立或首个 SSE 帧之前）
 * 失败时才允许重试——此时请求是幂等的，重发不会造成重复文本或重复
 * 工具执行。一旦已经 yield 过事件，错误直接向调用方抛出，绝不重试，
 * 避免把已生成的内容再来一遍。
 */
export async function* streamWithRetry<T>(
  factory: () => AsyncIterable<T>,
  isRetryable: (error: unknown) => boolean = isRetryableModelError,
  options: StreamRetryOptions = {}
): AsyncGenerator<T> {
  const maxAttempts = options.maxAttempts ?? 3;
  const baseDelayMs = options.baseDelayMs ?? 1_000;
  const sleep = options.sleep ?? defaultSleep;

  let attempt = 0;
  let iterator: AsyncIterator<T>;
  while (true) {
    attempt += 1;
    iterator = factory()[Symbol.asyncIterator]();
    try {
      const first = await iterator.next();
      if (first.done) return;
      yield first.value;
      break;
    } catch (error) {
      if (attempt >= maxAttempts || !isRetryable(error)) throw error;
      options.onRetry?.(attempt, error);
      await sleep(baseDelayMs * attempt);
    }
  }

  // 首事件已安全产出，之后的事件直接透传，不再重试。
  while (true) {
    const next = await iterator.next();
    if (next.done) return;
    yield next.value;
  }
}
