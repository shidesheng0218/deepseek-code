import { mkdtemp, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { createFileSecretStore, shellCommand, userConfigDir, userDataDir } from '../../src/core/platform';

describe('platform', () => {
  test('macOS paths keep the current layout', () => {
    const env = { HOME: '/Users/test' } as NodeJS.ProcessEnv;
    expect(userDataDir('DeepSeekCode', env, 'darwin')).toBe('/Users/test/Library/Application Support/DeepSeekCode');
    expect(userConfigDir(env, 'darwin')).toBe('/Users/test/.deepseek');
  });

  test('linux follows XDG directories', () => {
    const env = { HOME: '/home/test', XDG_CONFIG_HOME: '/home/test/.config', XDG_DATA_HOME: '/home/test/.local/share' } as NodeJS.ProcessEnv;
    expect(userConfigDir(env, 'linux')).toBe('/home/test/.config/deepseek');
    expect(userDataDir('DeepSeekCode', env, 'linux')).toBe('/home/test/.local/share/DeepSeekCode');
  });

  test('windows uses roaming/local app data and cmd shell', () => {
    const env = { USERPROFILE: 'C:\\Users\\test', APPDATA: 'C:\\Users\\test\\AppData\\Roaming', LOCALAPPDATA: 'C:\\Users\\test\\AppData\\Local' } as NodeJS.ProcessEnv;
    expect(userConfigDir(env, 'win32')).toBe('C:\\Users\\test\\AppData\\Roaming/DeepSeekCode');
    expect(userDataDir('DeepSeekCode', env, 'win32')).toContain('AppData\\Local');
    expect(shellCommand('win32').file).toContain('cmd');
    expect(shellCommand('darwin')).toEqual({ file: '/bin/sh', args: ['-lc'] });
  });

  test('file secret store round-trips values with 0600 permissions', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'deepseek-secrets-'));
    const store = createFileSecretStore(join(dir, 'secrets.json'));
    expect(await store.get('apiKey')).toBeUndefined();
    await store.set('apiKey', 'sk-test-123');
    expect(await store.get('apiKey')).toBe('sk-test-123');
    const mode = (await stat(join(dir, 'secrets.json'))).mode & 0o777;
    expect(mode).toBe(0o600);
    await store.delete('apiKey');
    expect(await store.get('apiKey')).toBeUndefined();
    expect(JSON.parse(await readFile(join(dir, 'secrets.json'), 'utf8'))).toEqual({});
  });
});
