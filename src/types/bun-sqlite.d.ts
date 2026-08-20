/**
 * bun:sqlite 的最小类型声明（仅覆盖 session-projection 用到的 API 面）。
 * Sidecar 由 Bun 编译运行时提供该模块；Node 环境下 import 会失败并回退 node:sqlite。
 */
declare module 'bun:sqlite' {
  export class Database {
    constructor(path: string);
    exec(sql: string): unknown;
    prepare(sql: string): {
      run(...params: Array<string | number | null>): unknown;
      get(...params: Array<string | number | null>): Record<string, unknown> | undefined;
      all(...params: Array<string | number | null>): Array<Record<string, unknown>>;
    };
    close(): void;
  }
}
