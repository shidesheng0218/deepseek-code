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
 * 一个持有真实系统资源（子进程、socket、fd）的会话级句柄。main.ts 里的
 * terminals/sshTerminals/mcpClients/lspClients 四个 Map 存的都是这种东西——
 * 不清理不是"多占了点内存"，是子进程和连接一直不关，是真实的资源泄漏。
 */
export interface DisposableResource {
  close(): void | Promise<void>;
}

/**
 * 一个可被清理的会话级资源登记表：sessionID -> 资源。
 * SessionDataCleaner 不知道具体是终端还是 MCP 客户端，只知道"idle 就该关掉"。
 */
export interface SessionResourceRegistry {
  entries(): IterableIterator<[string, DisposableResource]>;
  delete(sessionID: string): boolean;
}

/**
 * 会话数据清理器：关闭空闲会话持有的真实资源（终端子进程、MCP/LSP 连接），
 * 不是泛泛的"清理缓存"——这个模块此前完全没被任何地方 import，是彻底的死代码，
 * cleanup() 里量的是清理前后堆大小差，从未真正释放任何东西。
 *
 * main.ts 在装配时把它管理的 Map 注册进来（registerResource），并提供
 * isIdle(sessionID) 判断（复用 main.ts 已有的 activeSessions/activeControllers），
 * 这样清理逻辑知道"这个会话现在没有活跃 turn，关掉它的终端/连接是安全的"。
 */
export class SessionDataCleaner {
  private cleanupInterval: NodeJS.Timeout | undefined;
  private readonly registries: Array<{ name: string; registry: SessionResourceRegistry }> = [];
  private isIdle: (sessionID: string) => boolean = () => false;

  /** 注册一个资源表，供 cleanup() 扫描。name 只用于日志，便于分辨关的是哪一类资源。 */
  registerResource(name: string, registry: SessionResourceRegistry): void {
    this.registries.push({ name, registry });
  }

  /** 由调用方（main.ts）告知"这个会话是否空闲"，本模块不重新发明会话状态判断。 */
  setIdleCheck(check: (sessionID: string) => boolean): void {
    this.isIdle = check;
  }

  /**
   * 开始定期清理
   */
  start(intervalMs: number = 60000): void {
    this.cleanupInterval = setInterval(() => {
      void this.cleanup();
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
   * 执行清理：关闭所有已注册资源表里、当前空闲的会话持有的资源。
   * 返回实际关闭的资源数，供调用方/测试判断清理是否真的发生了。
   */
  async cleanup(): Promise<number> {
    let closed = 0;
    for (const { name, registry } of this.registries) {
      const idleSessionIDs: string[] = [];
      for (const [sessionID] of registry.entries()) {
        if (this.isIdle(sessionID)) idleSessionIDs.push(sessionID);
      }
      for (const sessionID of idleSessionIDs) {
        const resource = [...registry.entries()].find(([id]) => id === sessionID)?.[1];
        if (!resource) continue;
        try {
          await resource.close();
        } catch {
          // 资源已经处于异常状态（进程早退等），关闭失败不阻塞其余清理
        }
        registry.delete(sessionID);
        closed += 1;
      }
      if (idleSessionIDs.length > 0) console.log(`[SessionDataCleaner] Closed ${idleSessionIDs.length} idle ${name} resource(s)`);
    }
    return closed;
  }
}

/**
 * 全局实例
 */
export const memoryMonitor = new MemoryMonitor();
export const sessionCleaner = new SessionDataCleaner();
