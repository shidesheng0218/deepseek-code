/**
 * 代码图谱缓存层（性能优化）
 *
 * 功能：
 * - 索引缓存：基于文件 mtime
 * - 符号卡 LRU 缓存
 * - 增量更新：只重新索引修改的文件
 */

import { statSync } from 'node:fs';

export interface CacheEntry<T> {
  mtime: number;
  data: T;
}

export class CodeGraphCache {
  private indexCache = new Map<string, CacheEntry<any>>();
  private symbolCardCache = new Map<string, { timestamp: number; card: string }>();
  private readonly SYMBOL_CARD_CACHE_SIZE = 100;
  private readonly SYMBOL_CARD_CACHE_TTL = 5 * 60 * 1000; // 5 分钟

  /**
   * 检查索引是否需要更新
   */
  needsUpdate(filePath: string): boolean {
    try {
      const stat = statSync(filePath);
      const cached = this.indexCache.get(filePath);

      if (!cached) return true;
      return stat.mtimeMs > cached.mtime;
    } catch {
      return true;
    }
  }

  /**
   * 获取缓存的索引
   */
  getIndex<T>(filePath: string): T | undefined {
    const cached = this.indexCache.get(filePath);
    if (!cached) return undefined;

    try {
      const stat = statSync(filePath);
      if (stat.mtimeMs > cached.mtime) {
        this.indexCache.delete(filePath);
        return undefined;
      }
      return cached.data as T;
    } catch {
      this.indexCache.delete(filePath);
      return undefined;
    }
  }

  /**
   * 设置索引缓存
   */
  setIndex<T>(filePath: string, data: T): void {
    try {
      const stat = statSync(filePath);
      this.indexCache.set(filePath, {
        mtime: stat.mtimeMs,
        data
      });
    } catch {
      // 文件不存在，不缓存
    }
  }

  /**
   * 获取符号卡缓存（LRU）
   */
  getSymbolCard(key: string): string | undefined {
    const cached = this.symbolCardCache.get(key);
    if (!cached) return undefined;

    const age = Date.now() - cached.timestamp;
    if (age > this.SYMBOL_CARD_CACHE_TTL) {
      this.symbolCardCache.delete(key);
      return undefined;
    }

    return cached.card;
  }

  /**
   * 设置符号卡缓存（LRU）
   */
  setSymbolCard(key: string, card: string): void {
    // LRU 驱逐
    if (this.symbolCardCache.size >= this.SYMBOL_CARD_CACHE_SIZE) {
      const oldestKey = this.symbolCardCache.keys().next().value;
      if (oldestKey) {
        this.symbolCardCache.delete(oldestKey);
      }
    }

    this.symbolCardCache.set(key, {
      timestamp: Date.now(),
      card
    });
  }

  /**
   * 清空缓存
   */
  clear(): void {
    this.indexCache.clear();
    this.symbolCardCache.clear();
  }

  /**
   * 获取缓存统计
   */
  getStats() {
    return {
      indexCacheSize: this.indexCache.size,
      symbolCardCacheSize: this.symbolCardCache.size,
      memoryUsage: this.estimateMemoryUsage()
    };
  }

  /**
   * 估算内存使用（字节）
   */
  private estimateMemoryUsage(): number {
    let bytes = 0;

    // 索引缓存
    for (const [key, value] of this.indexCache) {
      bytes += key.length * 2; // 字符串 UTF-16
      bytes += JSON.stringify(value.data).length * 2;
    }

    // 符号卡缓存
    for (const [key, value] of this.symbolCardCache) {
      bytes += key.length * 2;
      bytes += value.card.length * 2;
    }

    return bytes;
  }
}

/**
 * 全局缓存实例
 */
export const codeGraphCache = new CodeGraphCache();
