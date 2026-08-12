import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { SecretVault } from '../../src/core/security/secret-vault';

describe('secret vault', () => {
  test('stores an encrypted secret and never writes the plaintext key to disk', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'deepseek-vault-'));
    const storagePath = join(directory, 'secrets.json');
    const vault = new SecretVault({
      storagePath,
      crypto: {
        isEncryptionAvailable: () => true,
        encryptString: (value) => Buffer.from(`encrypted:${value}`),
        decryptString: (value) => value.toString().replace('encrypted:', '')
      }
    });

    await vault.save('keychain://deepseek-default', 'sk-secret-value');

    expect(await vault.load('keychain://deepseek-default')).toBe('sk-secret-value');
    expect(await readFile(storagePath, 'utf8')).not.toContain('sk-secret-value');
  });
});
