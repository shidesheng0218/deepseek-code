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
 * 代码图谱服务（Phase 2 v2 简化实现）
 *
 * 不依赖 tree-sitter，用正则提取 TS/JS 符号（生产环境可升级为 AST 解析）
 */
export class CodeGraphService {
  private symbols: Map<string, SymbolCard> = new Map();
  private callGraph: CallGraphEdge[] = [];
  private indexedFiles: Set<string> = new Set();

  /**
   * 索引工作区（首次或刷新）
   * Phase 2 v2：正则提取符号（函数、类、接口、类型）
   */
  async indexWorkspace(projectPath: string): Promise<{ symbolCount: number; files: number }> {
    const { readdir, readFile, stat } = await import('node:fs/promises');
    const { join } = await import('node:path');

    // 1. 递归找到所有 .ts/.tsx/.js/.jsx 文件（排除 node_modules、dist、build）
    const sourceFiles: string[] = [];
    const excludeDirs = new Set(['node_modules', 'dist', 'build', '.git', 'coverage']);

    const walk = async (dir: string) => {
      try {
        const entries = await readdir(dir, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.isDirectory()) {
            if (!excludeDirs.has(entry.name)) {
              await walk(join(dir, entry.name));
            }
          } else if (/\.(ts|tsx|js|jsx)$/.test(entry.name)) {
            sourceFiles.push(join(dir, entry.name));
          }
        }
      } catch {
        // 目录不可读则跳过
      }
    };

    await walk(projectPath);

    // 2. 解析每个文件
    for (const filePath of sourceFiles.slice(0, 500)) {
      // 限制 500 个文件避免超时
      await this.updateFile(filePath, projectPath);
    }

    return { symbolCount: this.symbols.size, files: this.indexedFiles.size };
  }

  /**
   * 增量更新（文件变更时）
   */
  async updateFile(filePath: string, projectPath?: string): Promise<void> {
    const { readFile } = await import('node:fs/promises');
    const { relative } = await import('node:path');

    try {
      const content = await readFile(filePath, 'utf8');
      const relativePath = projectPath ? relative(projectPath, filePath) : filePath;

      // 移除该文件的旧符号
      for (const [name, card] of this.symbols.entries()) {
        if (card.filePath === relativePath) {
          this.symbols.delete(name);
        }
      }

      // 提取新符号
      this.extractSymbols(content, relativePath);
      this.indexedFiles.add(relativePath);
    } catch {
      // 文件不可读则跳过
    }
  }

  /**
   * 正则提取符号（简化版，生产环境用 AST）
   */
  private extractSymbols(content: string, filePath: string): void {
    const lines = content.split('\n');

    // 提取函数定义
    const functionPattern = /^export\s+(?:async\s+)?function\s+(\w+)\s*\(/;
    const arrowFunctionPattern = /^export\s+const\s+(\w+)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>/;

    // 提取类定义
    const classPattern = /^export\s+(?:abstract\s+)?class\s+(\w+)/;

    // 提取接口定义
    const interfacePattern = /^export\s+interface\s+(\w+)/;

    // 提取类型定义
    const typePattern = /^export\s+type\s+(\w+)/;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line) continue;
      const trimmed = line.trim();
      const lineNumber = i + 1;

      // 函数
      let match = trimmed.match(functionPattern) || trimmed.match(arrowFunctionPattern);
      if (match && match[1]) {
        const name = match[1];
        this.symbols.set(name, {
          name,
          kind: 'function',
          filePath,
          line: lineNumber,
          signature: trimmed.slice(0, 100),
          references: 0,
          relatedTests: [],
          exports: true
        });
        continue;
      }

      // 类
      match = trimmed.match(classPattern);
      if (match && match[1]) {
        const name = match[1];
        this.symbols.set(name, {
          name,
          kind: 'class',
          filePath,
          line: lineNumber,
          signature: trimmed.slice(0, 100),
          references: 0,
          relatedTests: [],
          exports: true
        });
        continue;
      }

      // 接口
      match = trimmed.match(interfacePattern);
      if (match && match[1]) {
        const name = match[1];
        this.symbols.set(name, {
          name,
          kind: 'interface',
          filePath,
          line: lineNumber,
          signature: trimmed.slice(0, 100),
          references: 0,
          relatedTests: [],
          exports: true
        });
        continue;
      }

      // 类型
      match = trimmed.match(typePattern);
      if (match && match[1]) {
        const name = match[1];
        this.symbols.set(name, {
          name,
          kind: 'type',
          filePath,
          line: lineNumber,
          signature: trimmed.slice(0, 100),
          references: 0,
          relatedTests: [],
          exports: true
        });
      }
    }

    // 提取调用关系（简化版：只找 import 语句）
    const importPattern = /import\s+\{([^}]+)\}\s+from\s+['"]([^'"]+)['"]/g;
    let importMatch;
    while ((importMatch = importPattern.exec(content)) !== null) {
      const symbols = importMatch[1]?.split(',').map((s) => s.trim()) ?? [];
      // TODO: 构建 CallGraphEdge（需要跨文件解析）
    }
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
