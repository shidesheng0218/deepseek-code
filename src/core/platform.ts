import { execFile as execFileCallback } from 'node:child_process';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

/**
 * 平台抽象：路径、Shell、密钥存储。
 * macOS 是一等支持目标；Linux/Windows 通过同一接口获得合理行为，
 * 让 Sidecar 与核心库不在各处置写 macOS 语义。
 */

export type SupportedPlatform = 'darwin' | 'linux' | 'win32';

function normalizePlatform(platform: string): SupportedPlatform {
  if (platform === 'darwin' || platform === 'linux' || platform === 'win32') return platform;
  return 'darwin';
}

export function homeDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.HOME ?? env.USERPROFILE ?? '.';
}

/** 用户级配置目录：~/.deepseek（macOS/Linux，遵循 XDG）或 %APPDATA%\DeepSeekCode。 */
export function userConfigDir(env: NodeJS.ProcessEnv = process.env, platform: string = process.platform): string {
  if (normalizePlatform(platform) === 'win32') return join(env.APPDATA ?? join(homeDir(env), 'AppData', 'Roaming'), 'DeepSeekCode');
  if (normalizePlatform(platform) === 'linux') return join(env.XDG_CONFIG_HOME ?? join(homeDir(env), '.config'), 'deepseek');
  return join(homeDir(env), '.deepseek');
}

/** 应用数据目录（会话日志等）。 */
export function userDataDir(appName: string, env: NodeJS.ProcessEnv = process.env, platform: string = process.platform): string {
  if (normalizePlatform(platform) === 'win32') return join(env.LOCALAPPDATA ?? join(homeDir(env), 'AppData', 'Local'), appName);
  if (normalizePlatform(platform) === 'linux') return join(env.XDG_DATA_HOME ?? join(homeDir(env), '.local', 'share'), appName);
  return join(homeDir(env), 'Library', 'Application Support', appName);
}

/** 执行 Shell 命令的解释器：Unix 用登录 shell，Windows 用 cmd。 */
export function shellCommand(platform: string = process.platform): { file: string; args: string[] } {
  if (normalizePlatform(platform) === 'win32') return { file: process.env.ComSpec ?? 'cmd.exe', args: ['/d', '/s', '/c'] };
  return { file: '/bin/sh', args: ['-lc'] };
}

export interface PlatformSecretStore {
  get(key: string): Promise<string | undefined>;
  set(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
}

/** macOS Keychain 实现（security CLI）。 */
export function createKeychainSecretStore(service: string): PlatformSecretStore {
  return {
    async get(key) {
      try {
        const result = await execFile('security', ['find-generic-password', '-s', service, '-a', key, '-w'], { maxBuffer: 100_000 });
        const value = result.stdout.trim();
        return value || undefined;
      } catch {
        return undefined;
      }
    },
    async set(key, value) {
      await execFile('security', ['add-generic-password', '-U', '-s', service, '-a', key, '-w', value], { maxBuffer: 100_000 });
    },
    async delete(key) {
      await execFile('security', ['delete-generic-password', '-s', service, '-a', key], { maxBuffer: 100_000 }).catch(() => undefined);
    }
  };
}

/**
 * 非 macOS 平台的文件回退：权限 0600 的 JSON 文件。
 * 注意：这是静止文件保护而非操作系统级保险箱，适用于开发/测试环境；
 * 生产 Linux 部署应替换为 libsecret 等系统钥匙串实现。
 */
export function createFileSecretStore(file: string): PlatformSecretStore {
  async function readAll(): Promise<Record<string, string>> {
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8'));
      return parsed && typeof parsed === 'object' ? parsed as Record<string, string> : {};
    } catch {
      return {};
    }
  }
  async function writeAll(values: Record<string, string>): Promise<void> {
    await mkdir(join(file, '..'), { recursive: true });
    await writeFile(file, JSON.stringify(values), { mode: 0o600 });
    await chmod(file, 0o600).catch(() => undefined);
  }
  return {
    async get(key) {
      return (await readAll())[key];
    },
    async set(key, value) {
      const values = await readAll();
      values[key] = value;
      await writeAll(values);
    },
    async delete(key) {
      const values = await readAll();
      delete values[key];
      await writeAll(values);
    }
  };
}

/** 按平台选择密钥存储：macOS 用 Keychain，其他平台用 0600 文件。 */
export function createPlatformSecretStore(
  service: string,
  env: NodeJS.ProcessEnv = process.env,
  platform: string = process.platform
): PlatformSecretStore {
  if (normalizePlatform(platform) === 'darwin') return createKeychainSecretStore(service);
  return createFileSecretStore(join(userConfigDir(env, platform), 'secrets.json'));
}
