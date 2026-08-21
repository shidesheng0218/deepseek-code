/**
 * Code Graph（NEXT_GEN_ARCHITECTURE Phase 2 支柱四）
 *
 * 符号级代码理解：替换 3-6 次 read_file + grep 为一次图谱查询
 *
 * vs Codex：
 * - Codex 有 file-search，无符号图谱
 * - 我们做符号卡 + 调用图 + 影响分析
 *
 * Phase 2 v1 简化版：
 * - 只做 TypeScript/JavaScript 符号提取（tree-sitter）
 * - 增量索引：文件变更时重建该文件的符号
 * - 失败降级：索引失败时退化为全文搜索
 */

export interface SymbolCard {
  name: string;
  kind: 'function' | 'class' | 'interface' | 'type' | 'const' | 'variable';
  filePath: string;
  line: number;
  signature?: string; // "function foo(a: string, b: number): Promise<void>"
  docComment?: string;
  references: number; // 被引用次数（跨文件）
  relatedTests: string[]; // 相关测试文件路径
  exports?: boolean; // 是否导出
}

export interface CallGraphEdge {
  from: string; // 符号名
  to: string; // 符号名
  filePath: string;
  line: number;
}

export interface ImpactAnalysis {
  changedSymbols: string[];
  affectedSymbols: string[]; // 调用链下游
  suggestedTests: string[]; // 基于调用图推荐的测试
  riskLevel: 'low' | 'medium' | 'high';
}

export interface ModuleMap {
  directory: string;
  exports: string[]; // 导出的符号名
  imports: Array<{ from: string; symbols: string[] }>;
  testCoverage?: number; // 0-100
}

/**
 * 代码图谱服务（Phase 2 v1 占位实现）
 */
export class CodeGraphService {
  private symbols: Map<string, SymbolCard> = new Map();
  private callGraph: CallGraphEdge[] = [];

  /**
   * 索引工作区（首次或刷新）
   * Phase 2 v1：占位实现，返回空图谱
   * Phase 2 v2：tree-sitter 解析 + 增量更新
   */
  async indexWorkspace(projectPath: string): Promise<{ symbolCount: number; files: number }> {
    // TODO: tree-sitter 解析所有 .ts/.js 文件
    // 1. 找到所有源文件（排除 node_modules）
    // 2. 解析每个文件的 AST
    // 3. 提取函数/类/接口定义 → SymbolCard
    // 4. 提取调用关系 → CallGraphEdge
    return { symbolCount: 0, files: 0 };
  }

  /**
   * 增量更新（文件变更时）
   */
  async updateFile(filePath: string): Promise<void> {
    // TODO: 重新解析单个文件，更新 symbols 和 callGraph
  }

  /**
   * 符号卡查询
   * 返回压缩版（≤500 字符），完整数据在 evidenceRef
   */
  getSymbolCard(name: string): SymbolCard | null {
    return this.symbols.get(name) ?? null;
  }

  /**
   * 调用图查询：谁调用了这个符号？
   */
  getCallers(symbolName: string, depth: number = 1): string[] {
    const callers = new Set<string>();
    const edges = this.callGraph.filter((edge) => edge.to === symbolName);

    for (const edge of edges) {
      callers.add(edge.from);
      if (depth > 1) {
        // 递归查找间接调用者
        for (const caller of this.getCallers(edge.from, depth - 1)) {
          callers.add(caller);
        }
      }
    }

    return Array.from(callers);
  }

  /**
   * 影响分析：给定 diff，返回受影响的符号和建议测试
   */
  analyzeImpact(changedFiles: string[]): ImpactAnalysis {
    const changedSymbols: string[] = [];

    // 找到变更文件中的所有符号
    for (const [name, card] of this.symbols.entries()) {
      if (changedFiles.includes(card.filePath)) {
        changedSymbols.push(name);
      }
    }

    // 找到调用这些符号的下游
    const affectedSymbols = new Set<string>();
    for (const symbol of changedSymbols) {
      for (const caller of this.getCallers(symbol, 2)) {
        affectedSymbols.add(caller);
      }
    }

    // 推荐测试：找到所有相关测试文件
    const suggestedTests = new Set<string>();
    for (const symbol of [...changedSymbols, ...affectedSymbols]) {
      const card = this.symbols.get(symbol);
      if (card) {
        for (const test of card.relatedTests) {
          suggestedTests.add(test);
        }
      }
    }

    // 风险评估：受影响符号越多，风险越高
    const riskLevel = affectedSymbols.size > 10 ? 'high' : affectedSymbols.size > 3 ? 'medium' : 'low';

    return {
      changedSymbols,
      affectedSymbols: Array.from(affectedSymbols),
      suggestedTests: Array.from(suggestedTests),
      riskLevel
    };
  }

  /**
   * 模块地图：目录级依赖摘要
   */
  getModuleMap(directory: string): ModuleMap {
    const exports: string[] = [];
    const imports: Array<{ from: string; symbols: string[] }> = [];

    // 找到目录下所有导出的符号
    for (const [name, card] of this.symbols.entries()) {
      if (card.filePath.startsWith(directory) && card.exports) {
        exports.push(name);
      }
    }

    return { directory, exports, imports };
  }

  /**
   * 失败降级：图谱不可用时返回 null，调用方退化为全文搜索
   */
  isAvailable(): boolean {
    return this.symbols.size > 0;
  }
}

/**
 * 全局实例（单例）
 */
export const codeGraph = new CodeGraphService();
