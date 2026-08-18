const privateKeyBlock = /-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g;
const bearerToken = /\b(Bearer\s+)[^\s'"`]+/gi;
const knownToken = /\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{12,}|AKIA[0-9A-Z]{16})\b/g;
const keyValueSecret = /\b(api[_-]?key|access[_-]?token|github[_-]?token|token|secret|password)\s*([=:])\s*([^\s,;]+)/gi;

export function redactSecrets(value: string): string {
  return value
    .replace(privateKeyBlock, '[REDACTED_PRIVATE_KEY]')
    .replace(bearerToken, '$1[REDACTED]')
    .replace(knownToken, '[REDACTED]')
    .replace(keyValueSecret, '$1$2[REDACTED]');
}
