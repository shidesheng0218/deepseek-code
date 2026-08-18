import { readFile, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import type { LanguageServerConfig } from './lsp-client';

export interface ConfiguredLanguageServer extends LanguageServerConfig {
  languages: string[];
}

export async function loadLanguageServerConfigs(projectRoot: string): Promise<ConfiguredLanguageServer[]> {
  try {
    const root = await realpath(projectRoot);
    const raw = JSON.parse(await readFile(join(root, '.deepseek', 'lsp.json'), 'utf8')) as { servers?: Array<Record<string, unknown>> };
    return (raw.servers ?? []).flatMap((server) => {
      if (typeof server.command !== 'string') return [];
      const languages = Array.isArray(server.languages) ? server.languages.filter((item): item is string => typeof item === 'string') : [];
      if (!languages.length) return [];
      const args = Array.isArray(server.args) ? server.args.filter((item): item is string => typeof item === 'string') : [];
      return [{ command: server.command, args, rootPath: root, languages }];
    }).slice(0, 16);
  } catch { return []; }
}
