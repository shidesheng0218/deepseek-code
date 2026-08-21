/**
 * Sandbox Service（NEXT_GEN_ARCHITECTURE Phase 5）
 *
 * 沙箱隔离：限制命令的文件系统和网络访问
 *
 * vs Codex：
 * - Codex 用 bubblewrap (Linux) + Seatbelt (macOS)
 * - 我们实现 macOS Sandbox + 违规追踪
 *
 * Phase 5 完整版：
 * - macOS: sandbox-exec with profile
 * - Linux: bubblewrap (TODO)
 * - 违规追踪：记录越界访问尝试
 */

import { spawn } from 'node:child_process';
import { writeFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export interface SandboxConfig {
  allowedPaths: string[]; // 允许读写的路径
  allowNetwork: boolean; // 是否允许网络访问
  allowedHosts?: string[]; // 允许访问的主机（如果 allowNetwork=true）
  timeoutMs: number; // 超时时间
}

export interface SandboxResult {
  ok: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  violations: Array<{
    type: 'file' | 'network';
    path?: string;
    host?: string;
    operation: string;
  }>;
  sandboxed: boolean;
}

/**
 * macOS Sandbox Profile 生成器
 */
function generateMacOSSandboxProfile(config: SandboxConfig): string {
  const allowedPathsRules = config.allowedPaths
    .map((path) => `(allow file* (subpath "${path}"))`)
    .join('\n    ');

  return `(version 1)
(deny default)
(allow process*)
(allow sysctl-read)
(allow mach-lookup (global-name-regex #"^com\\.apple\\..*"))

; 允许指定路径的文件操作
${allowedPathsRules}

; 允许 /tmp 和 /private/tmp
(allow file* (subpath "/tmp"))
(allow file* (subpath "/private/tmp"))

; 允许标准输入输出
(allow file-read* file-write* (literal "/dev/null"))
(allow file-read* file-write* (literal "/dev/stdin"))
(allow file-read* file-write* (literal "/dev/stdout"))
(allow file-read* file-write* (literal "/dev/stderr"))

; 网络访问
${config.allowNetwork ? '(allow network*)' : '(deny network*)'}
`;
}

/**
 * Sandbox 服务
 */
export class SandboxService {
  /**
   * 在沙箱中执行命令（macOS）
   */
  async executeSandboxed(command: string, config: SandboxConfig): Promise<SandboxResult> {
    const platform = process.platform;

    if (platform === 'darwin') {
      return this.executeMacOS(command, config);
    } else if (platform === 'linux') {
      // TODO: bubblewrap 实现
      throw new Error('Linux sandbox not implemented yet (use bubblewrap)');
    } else {
      // 不支持的平台，直接执行（无沙箱）
      return this.executeUnsandboxed(command, config);
    }
  }

  /**
   * macOS 沙箱执行
   */
  private async executeMacOS(command: string, config: SandboxConfig): Promise<SandboxResult> {
    // 生成沙箱配置文件
    const profilePath = join(tmpdir(), `sandbox-${Date.now()}.sb`);
    const profile = generateMacOSSandboxProfile(config);
    writeFileSync(profilePath, profile);

    try {
      // 使用 sandbox-exec 执行命令
      const result = await this.spawnProcess('sandbox-exec', ['-f', profilePath, 'sh', '-c', command], config.timeoutMs);

      // 解析 stderr 中的违规信息
      const violations = this.parseViolations(result.stderr);

      unlinkSync(profilePath);

      return {
        ok: result.exitCode === 0,
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        violations,
        sandboxed: true
      };
    } catch (error) {
      unlinkSync(profilePath);
      throw error;
    }
  }

  /**
   * 无沙箱执行（fallback）
   */
  private async executeUnsandboxed(command: string, config: SandboxConfig): Promise<SandboxResult> {
    const result = await this.spawnProcess('sh', ['-c', command], config.timeoutMs);

    return {
      ok: result.exitCode === 0,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      violations: [],
      sandboxed: false
    };
  }

  /**
   * 解析沙箱违规信息
   */
  private parseViolations(stderr: string): Array<{ type: 'file' | 'network'; path?: string; host?: string; operation: string }> {
    const violations: Array<{ type: 'file' | 'network'; path?: string; host?: string; operation: string }> = [];

    // macOS sandbox-exec 违规格式：
    // "Sandbox: sh(12345) deny(1) file-read-data /restricted/path"
    const lines = stderr.split('\n');
    for (const line of lines) {
      if (line.includes('Sandbox:') && line.includes('deny')) {
        // 文件访问违规
        const fileMatch = line.match(/deny\(\d+\)\s+(file-[^\s]+)\s+(.+)/);
        if (fileMatch && fileMatch[1] && fileMatch[2]) {
          violations.push({
            type: 'file',
            path: fileMatch[2].trim(),
            operation: fileMatch[1]
          });
        }

        // 网络访问违规
        const networkMatch = line.match(/deny\(\d+\)\s+(network-[^\s]+)\s+(.+)/);
        if (networkMatch && networkMatch[1] && networkMatch[2]) {
          violations.push({
            type: 'network',
            host: networkMatch[2].trim(),
            operation: networkMatch[1]
          });
        }
      }
    }

    return violations;
  }

  /**
   * 执行子进程
   */
  private spawnProcess(command: string, args: string[], timeoutMs: number): Promise<{
    exitCode: number;
    stdout: string;
    stderr: string;
  }> {
    return new Promise((resolve, reject) => {
      const child = spawn(command, args, { timeout: timeoutMs });

      let stdout = '';
      let stderr = '';

      child.stdout?.on('data', (data) => {
        stdout += data.toString();
      });

      child.stderr?.on('data', (data) => {
        stderr += data.toString();
      });

      child.on('close', (code) => {
        resolve({
          exitCode: code ?? -1,
          stdout,
          stderr
        });
      });

      child.on('error', (error) => {
        reject(error);
      });
    });
  }

  /**
   * 检查沙箱是否可用
   */
  static isAvailable(): boolean {
    const platform = process.platform;
    if (platform === 'darwin') {
      // macOS 有内置的 sandbox-exec
      return true;
    } else if (platform === 'linux') {
      // TODO: 检查 bubblewrap 是否安装
      return false;
    }
    return false;
  }
}

/**
 * 全局实例
 */
export const sandboxService = new SandboxService();
