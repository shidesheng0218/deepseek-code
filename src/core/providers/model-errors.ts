/**
 * 模型调用的结构化错误与用户可读描述。
 *
 * Provider 原始错误（HTTP 状态码、英文报文、网络异常）在这里统一分类，
 * 供两处消费：
 * 1. 重试层用 `retryable` 判断能否安全重试（限流/服务端故障/超时可以，鉴权不行）；
 * 2. 会话层用 `describeModelError` 给用户一句可行动的中文提示，
 *    而不是把 provider 的原始英文报文直接扔到界面上。
 */
export class ModelRequestError extends Error {
  constructor(
    message: string,
    readonly code: 'http_error' | 'timeout' | 'network_error' | 'malformed_tool_arguments',
    readonly retryable: boolean,
    readonly status?: number
  ) {
    super(message);
    this.name = 'ModelRequestError';
  }
}

/** 单次模型请求的整体超时。流式生成 8192 token 可能需要几分钟，
 *  上限取 5 分钟：足以覆盖正常长生成，又能终结"provider 挂起导致整轮
 *  任务永久卡住、只能按 Esc"的情况。 */
export const MODEL_STREAM_TIMEOUT_MS = 300_000;

const RETRYABLE_STATUSES = new Set([408, 409, 429, 500, 502, 503, 504]);

export function httpError(status: number, detail: string): ModelRequestError {
  return new ModelRequestError(
    `Model request failed with ${status}: ${detail}`,
    'http_error',
    RETRYABLE_STATUSES.has(status),
    status
  );
}

export function isRetryableModelError(error: unknown): boolean {
  return error instanceof ModelRequestError && error.retryable;
}

/** 把用户取消信号与整体超时合并成一个 fetch signal。
 *  `isTimeout()` 用于事后区分"超时中止"与"用户主动取消"：
 *  前者可重试，后者必须原样向上传播。 */
export function mergedStreamSignal(userSignal: AbortSignal | undefined, timeoutMs: number): { signal: AbortSignal; isTimeout: () => boolean } {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const onUserAbort = (): void => controller.abort();
  if (userSignal) {
    if (userSignal.aborted) controller.abort();
    else userSignal.addEventListener('abort', onUserAbort, { once: true });
  }
  controller.signal.addEventListener('abort', () => {
    clearTimeout(timer);
    userSignal?.removeEventListener('abort', onUserAbort);
  }, { once: true });
  return { signal: controller.signal, isTimeout: () => timedOut };
}

/** 把模型调用失败翻译为可行动的中文提示；非模型错误原样返回。 */
export function describeModelError(error: unknown): string {
  if (!(error instanceof ModelRequestError)) return error instanceof Error ? error.message : String(error);
  const raw = error.message.length > 200 ? `${error.message.slice(0, 200)}…` : error.message;
  switch (error.code) {
    case 'timeout':
      return '模型服务响应超时（超过 5 分钟无响应）。请重试；若持续出现，请检查网络或在设置中更换 Base URL。';
    case 'network_error':
      return '无法连接模型服务。请检查网络连接和设置中的 Base URL 是否正确。';
    case 'malformed_tool_arguments':
      return `模型返回了损坏的工具调用参数，本轮已安全中止（未执行任何不完整操作）。请重试该任务。`;
    case 'http_error':
      if (error.status === 401) return 'API Key 无效或已过期（401）。请在设置中检查并更新 API Key。';
      if (error.status === 402) return '账户余额不足或套餐受限（402）。请前往服务商控制台充值或调整套餐。';
      if (error.status === 403) return '没有访问该模型或接口的权限（403）。请确认模型名称与账户权限。';
      if (error.status === 404) return '模型或接口不存在（404）。请检查设置中的模型名称和 Base URL。';
      if (error.status === 429) return '模型服务限流（429），已自动重试仍失败。请稍后重试，或检查账户的速率限制。';
      if (error.status !== undefined && error.status >= 500) return `模型服务端故障（${error.status}），已自动重试仍失败。请稍后重试；服务商状态页可确认是否为平台问题。`;
      return `模型请求失败${error.status !== undefined ? `（${error.status}）` : ''}：${raw}`;
  }
}
