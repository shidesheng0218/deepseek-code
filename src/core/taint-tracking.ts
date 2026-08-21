/**
 * Taint Tracking（NEXT_GEN_ARCHITECTURE Phase 3）
 *
 * 数据流安全：追踪不可信输入在系统中的传播
 *
 * vs Codex：
 * - Codex 只管"能不能跑"（Exec Policy）
 * - 我们管"参数是否被污染"（数据流分析）
 *
 * Phase 3 完整版：
 * - 参数污点标记：自动检测来源
 * - 数据流追踪：跟踪污点传播
 * - 自动拦截：工具调用前检查污点 + 升级 Decision
 */

export type TaintSource = 'prompt_injection' | 'external_api' | 'user_input' | 'file_upload' | 'clean';

export interface TaintLabel {
  source: TaintSource;
  origin: string; // 污点来源描述（例如："web_fetch https://evil.com"）
  timestamp: number;
  propagationPath: string[]; // 污点传播路径（变量名链）
}

export interface TaintedValue {
  value: unknown;
  taints: TaintLabel[];
}

/**
 * 污点追踪服务
 */
export class TaintTracker {
  private taintedValues: Map<string, TaintLabel[]> = new Map();

  /**
   * 标记污点：来自不可信源的数据
   */
  mark(key: string, source: TaintSource, origin: string): void {
    const label: TaintLabel = {
      source,
      origin,
      timestamp: Date.now(),
      propagationPath: [key]
    };

    const existing = this.taintedValues.get(key) ?? [];
    existing.push(label);
    this.taintedValues.set(key, existing);
  }

  /**
   * 传播污点：变量赋值或字符串拼接时
   */
  propagate(fromKey: string, toKey: string): void {
    const sourceTaints = this.taintedValues.get(fromKey);
    if (!sourceTaints) return;

    const propagated = sourceTaints.map((label) => ({
      ...label,
      propagationPath: [...label.propagationPath, toKey]
    }));

    const existing = this.taintedValues.get(toKey) ?? [];
    this.taintedValues.set(toKey, [...existing, ...propagated]);
  }

  /**
   * 检查污点：工具调用前验证参数
   */
  check(key: string): TaintLabel[] {
    return this.taintedValues.get(key) ?? [];
  }

  /**
   * 清除污点：值经过验证或清洗后
   */
  clear(key: string): void {
    this.taintedValues.delete(key);
  }

  /**
   * 自动检测参数来源（Phase 3 核心）
   */
  detectSource(value: unknown, context: {
    toolName: string;
    previousToolCalls: Array<{ name: string; result: unknown }>;
  }): TaintSource {
    const stringValue = String(value);

    // 1. 检查是否来自 web_fetch / web_search（外部 API）
    const webTools = context.previousToolCalls.filter((call) =>
      call.name === 'web_fetch' || call.name === 'web_search'
    );
    for (const call of webTools) {
      const resultStr = JSON.stringify(call.result);
      if (resultStr.includes(stringValue.slice(0, 50))) {
        return 'external_api';
      }
    }

    // 2. 检查是否包含 prompt injection 特征
    const injectionPatterns = [
      /ignore\s+(previous|all)\s+instructions?/i,
      /you\s+are\s+(now|a)\s+/i,
      /system\s*:/i,
      /<\|.*?\|>/,  // 特殊 token
      /\[INST\]/i,
      /\{\{.*?\}\}/  // 模板注入
    ];

    for (const pattern of injectionPatterns) {
      if (pattern.test(stringValue)) {
        return 'prompt_injection';
      }
    }

    // 3. 检查是否来自用户输入文件
    if (context.previousToolCalls.some((call) => call.name === 'read_file')) {
      return 'user_input';
    }

    return 'clean';
  }

  /**
   * 分析工具调用的污点风险
   */
  analyzeToolCall(toolName: string, params: Record<string, unknown>, context: {
    previousToolCalls: Array<{ name: string; result: unknown }>;
  }): {
    hasTaint: boolean;
    taintedParams: Array<{ param: string; source: TaintSource; origin: string }>;
    riskLevel: 'low' | 'medium' | 'high';
  } {
    const taintedParams: Array<{ param: string; source: TaintSource; origin: string }> = [];

    // 检查每个参数
    for (const [param, value] of Object.entries(params)) {
      const key = `${toolName}.${param}`;
      const existingTaints = this.check(key);

      if (existingTaints.length > 0) {
        // 已标记的污点
        for (const taint of existingTaints) {
          taintedParams.push({ param, source: taint.source, origin: taint.origin });
        }
      } else {
        // 自动检测
        const source = this.detectSource(value, { toolName, previousToolCalls: context.previousToolCalls });
        if (source !== 'clean') {
          const origin = `${toolName} 参数 ${param}`;
          this.mark(key, source, origin);
          taintedParams.push({ param, source, origin });
        }
      }
    }

    // 风险评级
    let riskLevel: 'low' | 'medium' | 'high' = 'low';
    if (taintedParams.some((t) => t.source === 'prompt_injection')) {
      riskLevel = 'high'; // prompt injection 最危险
    } else if (taintedParams.some((t) => t.source === 'external_api')) {
      riskLevel = 'medium';
    } else if (taintedParams.length > 0) {
      riskLevel = 'medium';
    }

    return {
      hasTaint: taintedParams.length > 0,
      taintedParams,
      riskLevel
    };
  }

  /**
   * 生成污点报告（调试用）
   */
  report(): Array<{ key: string; taints: TaintLabel[] }> {
    const entries: Array<{ key: string; taints: TaintLabel[] }> = [];
    for (const [key, taints] of this.taintedValues.entries()) {
      entries.push({ key, taints });
    }
    return entries;
  }
}

/**
 * 全局单例
 */
export const taintTracker = new TaintTracker();
