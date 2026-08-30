/**
 * Sandbox Service（NEXT_GEN_ARCHITECTURE Phase 5）
 *
 * 沙箱隔离：限制命令的文件系统和网络访问
 *
 * vs Codex：
 * - Codex 用 bubblewrap (Linux) + Seatbelt (macOS)
 * - 我们实现 macOS Sandbox + Linux bubblewrap + 违规追踪
 *
 * 平台能力不对称，这里如实说明，不假装两边一样强：
 * - macOS sandbox-exec 的拒绝记录走内核统一日志（`log show`），不会出现在被拒绝
 *   进程自己的 stderr 里——早期实现假设它会出现在 stderr，实测发现从未真正捕获到
 *   任何违规。现在按执行时间窗口查 `log show` 取真实记录（queryViolations()）。
 * - Linux bwrap 靠 mount namespace 隔离，被挡的文件访问只会在目标命令自己的
 *   stderr 里表现为普通的 ENOENT/EACCES，没有类似 sandbox-exec 的结构化拒绝日志。
 *   所以 Linux 路径的 violations 恒为空数组——不是没做，是这个隔离机制本身
 *   不产生可解析的违规记录，标了 sandboxed:true 但不假装有 macOS 那种可观测性。
 * - 本模块在 macOS 上开发验证过（真实跑通 sandbox-exec + log show 全流程）；
 *   Linux 路径没有真实 Linux 环境跑过，bwrap 命令行参数按其文档语义编写，
 *   请在真实 Linux 环境验证后再依赖它做安全边界。
 */

import { spawn, execFileSync } from 'node:child_process';
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

; sh 启动时会读根目录本身（getcwd 解析父目录）和常见前缀路径的元数据
; （Homebrew 的 shell 初始化钩子会探测 /opt/homebrew/opt/*）。缺了这两条，
; sh 会静默失败或打印 shell-init 错误但仍以 exit 0 退出——这是实测发现的：
; 原来的 profile 没有这两条规则，导致沙箱执行"看起来成功"但实际没跑通。
(allow file-read-metadata)
(allow file-read-data (literal "/"))
(allow file-read* (subpath "/usr"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/lib"))
(allow file-read* (subpath "/System"))

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
      return this.executeLinux(command, config);
    } else {
      // 不支持的平台，直接执行（无沙箱）
      return this.executeUnsandboxed(command, config);
    }
  }

  /**
   * Linux 沙箱执行：bubblewrap（bwrap）建 mount namespace 隔离。
   * 未装 bwrap 时降级为无沙箱执行（sandboxed:false），不静默假装隔离生效。
   */
  private async executeLinux(command: string, config: SandboxConfig): Promise<SandboxResult> {
    if (!(await this.isBwrapAvailable())) {
      return this.executeUnsandboxed(command, config);
    }

    const args: string[] = [
      '--die-with-parent', // 父进程（本 sidecar）退出时沙箱子进程一并终止，不留孤儿
      '--unshare-pid',
      '--proc', '/proc',
      '--dev', '/dev',
      '--tmpfs', '/tmp',
    ];

    // 只读挂载系统根目录的必要部分，允许写的路径单独 bind（不是只读）
    for (const readonlyRoot of ['/usr', '/bin', '/lib', '/lib64', '/etc']) {
      args.push('--ro-bind-try', readonlyRoot, readonlyRoot);
    }
    for (const allowedPath of config.allowedPaths) {
      args.push('--bind', allowedPath, allowedPath);
    }

    if (!config.allowNetwork) {
      args.push('--unshare-net');
    }
    // allowNetwork=true 时不加 --unshare-net，沙箱继承主机网络命名空间——
    // bwrap 没有 macOS sandbox-exec 那种按域名过滤的能力，allowedHosts 在
    // Linux 路径上不生效，这里如实留空不处理，不假装支持。

    args.push('sh', '-c', command);

    const result = await this.spawnProcess('bwrap', args, config.timeoutMs);
    return {
      ok: result.exitCode === 0,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      violations: [], // bwrap 不产生结构化违规日志，见文件头注释
      sandboxed: true
    };
  }

  private isBwrapAvailable(): Promise<boolean> {
    return new Promise((resolve) => {
      const check = spawn('which', ['bwrap']);
      check.on('close', (code) => resolve(code === 0));
      check.on('error', () => resolve(false));
    });
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
      const startedAt = new Date();
      // 使用 sandbox-exec 执行命令
      const result = await this.spawnProcess('sandbox-exec', ['-f', profilePath, 'sh', '-c', command], config.timeoutMs);
      const finishedAt = new Date();

      // sandbox-exec 的拒绝日志走内核统一日志（log show），不会出现在被拒绝进程
      // 自己的 stderr 里——之前 parseViolations(result.stderr) 永远拿不到任何东西，
      // 因为它在读一个从来不会包含这些行的流。改为按时间窗口查真实的系统日志。
      const violations = await this.queryViolations(startedAt, finishedAt);

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

  /** 忽略 /dev/dtracehelper、/dev/tty 等每次 sh/bash 启动都会触发的无害探测性拒绝——
   *  这些不代表命令真的想访问越权资源，全部原样上报只会把真实违规淹没在噪音里。 */
  private static readonly IGNORED_VIOLATION_PATHS = [/^\/dev\/dtracehelper$/, /^\/dev\/tty$/];

  private async queryViolations(startedAt: Date, finishedAt: Date): Promise<Array<{ type: 'file' | 'network'; path?: string; host?: string; operation: string }>> {
    const format = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
    // log show 的时间窗口按秒截断，往两边各扩 1 秒避免边界事件被截掉
    const start = new Date(startedAt.getTime() - 1_000);
    const end = new Date(finishedAt.getTime() + 1_000);

    try {
      const result = await this.spawnProcess('/usr/bin/log', [
        'show', '--style', 'compact',
        '--start', format(start), '--end', format(end),
        '--predicate', "eventMessage CONTAINS 'Sandbox' AND eventMessage CONTAINS 'deny'"
      ], 10_000);
      return this.parseViolationLog(result.stdout);
    } catch {
      // log show 本身失败（权限、环境限制）不应该让整次沙箱执行报错——
      // 降级为"未知是否有违规"，而不是抛出中断主流程。
      return [];
    }
  }

  private parseViolationLog(logOutput: string): Array<{ type: 'file' | 'network'; path?: string; host?: string; operation: string }> {
    const violations: Array<{ type: 'file' | 'network'; path?: string; host?: string; operation: string }> = [];
    for (const line of logOutput.split('\n')) {
      const fileMatch = line.match(/Sandbox:\s+\S+\(\d+\)\s+deny\(\d+\)\s+(file-[^\s]+)\s+(\S+)/);
      if (fileMatch && fileMatch[1] && fileMatch[2]) {
        const path = fileMatch[2];
        if (SandboxService.IGNORED_VIOLATION_PATHS.some((pattern) => pattern.test(path))) continue;
        violations.push({ type: 'file', path, operation: fileMatch[1] });
        continue;
      }
      const networkMatch = line.match(/Sandbox:\s+\S+\(\d+\)\s+deny\(\d+\)\s+(network-[^\s]+)\s+(\S+)/);
      if (networkMatch && networkMatch[1] && networkMatch[2]) {
        violations.push({ type: 'network', host: networkMatch[2], operation: networkMatch[1] });
      }
    }
    return violations;
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
   * 检查沙箱是否可用。同步方法（调用方可能在非 async 路径里用它做能力探测），
   * 用 execFileSync 而不是 spawn 版本的 isBwrapAvailable()——两者检查逻辑一致，
   * 只是同步/异步接口不同，服务于不同调用场景。
   */
  static isAvailable(): boolean {
    const platform = process.platform;
    if (platform === 'darwin') {
      // macOS 有内置的 sandbox-exec
      return true;
    } else if (platform === 'linux') {
      try {
        execFileSync('which', ['bwrap'], { stdio: 'ignore' });
        return true;
      } catch {
        return false;
      }
    }
    return false;
  }
}

/**
 * 全局实例
 */
export const sandboxService = new SandboxService();
