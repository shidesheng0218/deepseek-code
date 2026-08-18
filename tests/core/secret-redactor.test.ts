import { describe, expect, test } from 'vitest';
import { redactSecrets } from '../../src/core/secret-redactor';

describe('secret redactor', () => {
  test('removes common credentials before tool evidence enters a model context', () => {
    const source = [
      'Authorization: Bearer live-access-token',
      'GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz1234567890',
      'api_key: sk-abcdefghijklmnopqrstuvwxyz123456',
      '-----BEGIN PRIVATE KEY-----\nprivate material\n-----END PRIVATE KEY-----'
    ].join('\n');

    const redacted = redactSecrets(source);

    expect(redacted).not.toContain('live-access-token');
    expect(redacted).not.toContain('ghp_abcdefghijklmnopqrstuvwxyz1234567890');
    expect(redacted).not.toContain('sk-abcdefghijklmnopqrstuvwxyz123456');
    expect(redacted).not.toContain('private material');
    expect(redacted).toContain('[REDACTED]');
  });
});
