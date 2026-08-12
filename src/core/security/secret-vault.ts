import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

export interface SecretCrypto {
  isEncryptionAvailable(): boolean;
  encryptString(value: string): Buffer;
  decryptString(value: Buffer): string;
}

export class SecretVault {
  constructor(private readonly options: { storagePath: string; crypto: SecretCrypto }) {}

  private async readSecrets(): Promise<Record<string, string>> {
    try {
      return JSON.parse(await readFile(this.options.storagePath, 'utf8')) as Record<string, string>;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return {};
      throw error;
    }
  }

  async save(ref: string, secret: string): Promise<void> {
    if (!this.options.crypto.isEncryptionAvailable()) throw new Error('OS secure storage is unavailable');
    const secrets = await this.readSecrets();
    secrets[ref] = this.options.crypto.encryptString(secret).toString('base64');
    await mkdir(dirname(this.options.storagePath), { recursive: true });
    await writeFile(this.options.storagePath, JSON.stringify(secrets), { encoding: 'utf8', mode: 0o600 });
  }

  async load(ref: string): Promise<string | undefined> {
    const secrets = await this.readSecrets();
    const encoded = secrets[ref];
    if (!encoded) return undefined;
    return this.options.crypto.decryptString(Buffer.from(encoded, 'base64'));
  }
}
