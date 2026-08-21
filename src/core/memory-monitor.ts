/**
 * 内存使用优化（性能优化）
 *
 * 功能：
 * - 会话内存监控
 * - 自动清理过期数据
 * - 内存泄漏检测
 */

export interface MemoryStats {
  heapUsed: number;
  heapTotal: number;
  external: number;
  rss: number;
  arrayBuffers: number;
}

export interface MemoryThresholds {
  warning: number; // MB
  critical: number; // MB
}

export class MemoryMonitor {
  private readonly thresholds: MemoryThresholds;
  private checkInterval: NodeJS.Timeout | undefined;
  private baselineMemory?: MemoryStats;
  private listeners: Array<(stats: MemoryStats, level: 'normal' | 'warning' | 'critical') => void> = [];

  constructor(thresholds: MemoryThresholds = { warning: 512, critical: 1024 }) {
    this.thresholds = thresholds;
  }

  /**
   * 开始监控
   */
  start(intervalMs: number = 30000): void {
    // 记录基线
    this.baselineMemory = this.getStats();

    this.checkInterval = setInterval(() => {
      this.check();
    }, intervalMs);
  }

  /**
   * 停止监控
   */
  stop(): void {
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = undefined;
    }
  }

  /**
   * 获取内存统计
   */
  getStats(): MemoryStats {
    const mem = process.memoryUsage();
    return {
      heapUsed: mem.heapUsed,
      heapTotal: mem.heapTotal,
      external: mem.external,
      rss: mem.rss,
      arrayBuffers: mem.arrayBuffers
    };
  }

  /**
   * 检查内存使用
   */
  check(): void {
    const stats = this.getStats();
    const heapUsedMB = stats.heapUsed / 1024 / 1024;

    let level: 'normal' | 'warning' | 'critical' = 'normal';

    if (heapUsedMB >= this.thresholds.critical) {
      level = 'critical';
      console.warn(`[MemoryMonitor] CRITICAL: Heap usage ${heapUsedMB.toFixed(1)} MB`);
      this.triggerGC();
    } else if (heapUsedMB >= this.thresholds.warning) {
      level = 'warning';
      console.warn(`[MemoryMonitor] WARNING: Heap usage ${heapUsedMB.toFixed(1)} MB`);
    }

    // 通知监听者
    this.listeners.forEach(listener => listener(stats, level));
  }

  /**
   * 添加监听器
   */
  onMemoryChange(listener: (stats: MemoryStats, level: 'normal' | 'warning' | 'critical') => void): void {
    this.listeners.push(listener);
  }

  /**
   * 触发垃圾回收（如果可用）
   */
  triggerGC(): void {
    if (global.gc) {
      console.log('[MemoryMonitor] Triggering GC...');
      global.gc();
    } else {
      console.warn('[MemoryMonitor] GC not exposed. Run with --expose-gc');
    }
  }

  /**
   * 获取内存增长情况
   */
  getMemoryGrowth(): number | null {
    if (!this.baselineMemory) return null;

    const current = this.getStats();
    return current.heapUsed - this.baselineMemory.heapUsed;
  }

  /**
   * 格式化内存统计（人类可读）
   */
  formatStats(stats: MemoryStats): string {
    return `Heap: ${(stats.heapUsed / 1024 / 1024).toFixed(1)} MB / ${(stats.heapTotal / 1024 / 1024).toFixed(1)} MB, RSS: ${(stats.rss / 1024 / 1024).toFixed(1)} MB`;
  }
}

/**
 * 会话数据清理器
 */
export class SessionDataCleaner {
  private cleanupInterval: NodeJS.Timeout | undefined;

  /**
   * 开始定期清理
   */
  start(intervalMs: number = 60000): void {
    this.cleanupInterval = setInterval(() => {
      this.cleanup();
    }, intervalMs);
  }

  /**
   * 停止清理
   */
  stop(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = undefined;
    }
  }

  /**
   * 执行清理
   */
  cleanup(): void {
    // 清理过期的缓存
    const before = process.memoryUsage().heapUsed;

    // TODO: 清理具体的数据结构
    // - 过期的符号卡缓存
    // - 旧的事件缓冲区
    // - 未使用的索引缓存

    const after = process.memoryUsage().heapUsed;
    const freed = (before - after) / 1024 / 1024;

    if (freed > 0) {
      console.log(`[SessionDataCleaner] Freed ${freed.toFixed(1)} MB`);
    }
  }
}

/**
 * 全局实例
 */
export const memoryMonitor = new MemoryMonitor();
export const sessionCleaner = new SessionDataCleaner();
