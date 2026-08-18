export type CIFailureKind = 'dependency' | 'type' | 'test' | 'environment' | 'code';

export function classifyCIFailureLog(log: string): { kind: CIFailureKind; summary: string } {
  const text = log.toLowerCase();
  if (/eresolve|could not resolve dependency|lockfile|package .* not found|module not found/.test(text)) return { kind: 'dependency', summary: '依赖解析、锁文件或模块安装失败。' };
  if (/ts\d{4}|type .* is not assignable|cannot find name|swift.*error:.*cannot convert/.test(text)) return { kind: 'type', summary: '类型检查或编译接口不匹配。' };
  if (/\bfail\b|\bassertionerror\b|expected .* to be|test suite failed/.test(text)) return { kind: 'test', summary: '测试断言或测试套件失败。' };
  if (/missing environment|environment variable|permission denied|no such file|network is unreachable|service unavailable/.test(text)) return { kind: 'environment', summary: 'CI 环境、凭据、文件或网络条件不满足。' };
  return { kind: 'code', summary: '需要检查应用代码、运行时或未分类构建错误。' };
}
